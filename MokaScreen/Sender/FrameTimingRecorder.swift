// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Synchronization

/// Records how each frame travels from capture to the display Mac's glass for a few seconds, for
/// Develop › Record Frame Timing, and joins the records into one CSV row per capture.
///
/// Each kind of record has exactly one writer: captures the capture queue, sends the send
/// thread, and the display Mac's reports the acknowledgement thread. Storage is allocated with
/// the recorder, so recording takes no locks and allocates nothing on the hot path.
final class FrameTimingRecorder: Sendable {
	/// One capture handed to the sender.
	struct Capture: BitwiseCopyable, Equatable {
		/// ScreenCaptureKit's presentation time: when the virtual display refreshed, host ns.
		var captureTime: UInt64
		/// When the capture reached the sender, host ns.
		var submitTime: UInt64
		var dirtyRects: Int32
	}

	/// One frame written to the cable.
	struct Send: BitwiseCopyable, Equatable {
		var frameID: UInt64
		var captureTime: UInt64
		var startTime: UInt64
		var endTime: UInt64
		var bytes: Int64
		var rects: Int32
		var coverage: Float
	}

	/// Enough for 30 seconds at 120 Hz with room to spare.
	static let capacity = 4096

	let captures = RecordBuffer<Capture>(capacity: capacity)
	let sends = RecordBuffer<Send>(capacity: capacity)
	let displays = RecordBuffer<FrameTimingMessage>(capacity: capacity)
	private let active = Atomic<Bool>(false)

	var isActive: Bool { active.load(ordering: .relaxed) }

	/// Clears the previous recording and starts a new one.
	func start() {
		active.store(false, ordering: .sequentiallyConsistent)
		captures.reset()
		sends.reset()
		displays.reset()
		active.store(true, ordering: .sequentiallyConsistent)
	}

	func stop() {
		active.store(false, ordering: .sequentiallyConsistent)
	}

	/// Capture queue only.
	func record(_ capture: Capture) {
		if isActive { captures.append(capture) }
	}

	/// Send thread only.
	func record(_ send: Send) {
		if isActive { sends.append(send) }
	}

	/// Acknowledgement thread only.
	func record(_ display: FrameTimingMessage) {
		if isActive { displays.append(display) }
	}

	static let csvHeader = "capture_ms,capture_gap_ms,submit_lag_ms,dirty_rects,frame_id,send_start_lag_ms,send_ms,bytes,rects,coverage,received_ms,drawn_ms,glass_ms,glass_gap_ms,drawn_together,paced"

	/// One row per capture, oldest first. Times in each group share an origin: capture and send
	/// columns the first capture on this Mac's clock; received, drawn and glass columns the first
	/// frame received on the display Mac's clock. A capture with no frame ID was replaced by a
	/// newer one before it could be sent. `glass_gap_ms` is the time since the previous frame
	/// reached the glass; frames drawn together share a glass time.
	static func csv(captures: [Capture], sends: [Send], displays: [FrameTimingMessage]) -> String {
		var sendByCapture: [UInt64: Send] = [:]
		for send in sends where sendByCapture[send.captureTime] == nil {
			sendByCapture[send.captureTime] = send
		}
		var displayByFrame: [UInt64: FrameTimingMessage] = [:]
		for display in displays {
			displayByFrame[display.frameID] = display
		}
		let captureOrigin = captures.first?.captureTime ?? 0
		let receiveOrigin = displays.map { $0.drawTime &- UInt64($0.receivedBeforeDrawMicros) * 1000 }.min() ?? 0

		func ms(_ nanos: UInt64, from origin: UInt64) -> String {
			String(format: "%.3f", Double(Int64(bitPattern: nanos &- origin)) / 1e6)
		}

		var lines = [csvHeader]
		var previousCapture: UInt64?
		var previousGlass: UInt64?
		for capture in captures {
			var fields: [String] = [
				ms(capture.captureTime, from: captureOrigin),
				previousCapture.map { ms(capture.captureTime, from: $0) } ?? "",
				ms(capture.submitTime, from: capture.captureTime),
				String(capture.dirtyRects),
			]
			previousCapture = capture.captureTime
			if let send = sendByCapture[capture.captureTime] {
				fields += [
					String(send.frameID),
					ms(send.startTime, from: capture.captureTime),
					ms(send.endTime, from: send.startTime),
					String(send.bytes),
					String(send.rects),
					String(format: "%.4f", send.coverage),
				]
				if let display = displayByFrame[send.frameID] {
					let received = display.drawTime &- UInt64(display.receivedBeforeDrawMicros) * 1000
					var glassField = ""
					var gapField = ""
					if display.glassAfterDrawMicros >= 0 {
						let glass = display.drawTime &+ UInt64(display.glassAfterDrawMicros) * 1000
						glassField = ms(glass, from: receiveOrigin)
						gapField = previousGlass.map { ms(glass, from: $0) } ?? ""
						previousGlass = glass
					}
					fields += [
						ms(received, from: receiveOrigin),
						ms(display.drawTime, from: receiveOrigin),
						glassField,
						gapField,
						String(display.drawnTogether),
						display.paced ? "1" : "0",
					]
				} else {
					fields += Array(repeating: "", count: 6)
				}
			} else {
				fields += Array(repeating: "", count: 12)
			}
			lines.append(fields.joined(separator: ","))
		}
		return lines.joined(separator: "\n") + "\n"
	}

	/// Stops recording and writes the CSV to `~/Library/Logs/MokaScreen`.
	func write() throws -> URL {
		stop()
		let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MokaScreen")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
		let url = directory.appending(path: "frame-timing-\(formatter.string(from: Date())).csv")
		let text = Self.csv(captures: captures.snapshot(), sends: sends.snapshot(), displays: displays.snapshot())
		try Data(text.utf8).write(to: url)
		return url
	}
}

/// A fixed-capacity append-only buffer with a single writer thread and readers that read only
/// what was published before they looked. Appends past capacity are dropped.
final class RecordBuffer<Element: BitwiseCopyable>: @unchecked Sendable {
	private let storage: UnsafeMutablePointer<Element>
	let capacity: Int
	private let count = Atomic<Int>(0)

	init(capacity: Int) {
		self.capacity = capacity
		storage = .allocate(capacity: capacity)
	}

	deinit {
		storage.deallocate()
	}

	/// Writer thread only.
	func append(_ element: Element) {
		let n = count.load(ordering: .relaxed)
		guard n < capacity else { return }
		(storage + n).initialize(to: element)
		count.store(n + 1, ordering: .releasing)
	}

	func reset() {
		count.store(0, ordering: .releasing)
	}

	func snapshot() -> [Element] {
		Array(UnsafeBufferPointer(start: storage, count: count.load(ordering: .acquiring)))
	}
}
