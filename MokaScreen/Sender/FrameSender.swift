// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreVideo
import Foundation
import os

/// Streams captured frames to one receiver, newest frame first.
///
/// Latest-frame-wins: captures arrive on the capture queue and replace any frame still
/// waiting to be sent, while their dirty rectangles accumulate in a ``DirtyRegion``. The send
/// thread always takes the newest frame plus everything that changed since the receiver was
/// last updated, so a TCP stall delays the screen by at most one frame instead of building a
/// queue of stale ones.
final class FrameSender {
	/// Frames covering more than this fraction of the display are sent as one full-frame rectangle:
	/// rows are then contiguous in the capture buffer and go out as a single iovec.
	static let fullFrameThreshold = 0.85

	private let stream: ByteStream
	private let width: Int
	private let height: Int
	private let stats: SenderStats
	private let condition = NSCondition()
	private var pending: CapturedFrame?
	/// A Show Statistics change waiting to go out ahead of the next frame.
	private var pendingStatistics: Bool?
	private var dirty: DirtyRegion
	private var running = true
	private var nextFrameID: UInt64 = 1
	private let onClose: (Error) -> Void
	private let onStatistics: (Bool) -> Void
	/// Capture time of each recent frame, so `presented` acknowledgements yield latency.
	private let inflight = InflightFrames()

	/// Starts the send and acknowledgement threads on a stream that has completed the handshake.
	/// - Parameters:
	///   - showsStatistics: This Mac's Show Statistics setting, sent before the first frame so
	///     the receiver starts out matching it.
	///   - onStatistics: Called from a background thread when the receiver changes the setting.
	///   - onClose: Called once, from a background thread, when the connection fails.
	init(stream: ByteStream, width: Int, height: Int, stats: SenderStats, showsStatistics: Bool, onStatistics: @escaping (Bool) -> Void, onClose: @escaping (Error) -> Void) {
		self.stream = stream
		self.width = width
		self.height = height
		self.stats = stats
		self.onStatistics = onStatistics
		self.onClose = onClose
		pendingStatistics = showsStatistics
		dirty = DirtyRegion(width: width, height: height)
		dirty.insertAll()

		let sendThread = Thread { [self] in sendLoop() }
		sendThread.name = "MokaScreen.send"
		sendThread.qualityOfService = .userInteractive
		sendThread.start()

		let ackThread = Thread { [self] in ackLoop() }
		ackThread.name = "MokaScreen.ack"
		ackThread.qualityOfService = .userInitiated
		ackThread.start()
	}

	/// Hands over the newest capture. Called on the capture queue; never blocks on the network.
	func submit(_ frame: CapturedFrame) {
		condition.lock()
		for rect in frame.dirtyRects {
			dirty.insert(rect)
		}
		if pending != nil {
			stats.recordSuperseded()
		}
		pending = frame
		condition.signal()
		condition.unlock()
	}

	/// Tells the receiver to show or hide its statistics. Thread-safe; the message goes out on the
	/// send thread so it never lands inside a frame.
	func sendStatistics(visible: Bool) {
		condition.lock()
		pendingStatistics = visible
		condition.signal()
		condition.unlock()
	}

	/// Closes the connection and stops both threads.
	func stop() {
		condition.lock()
		running = false
		pending = nil
		condition.signal()
		condition.unlock()
		stream.close()
	}

	private func sendLoop() {
		var chunks = UnsafeMutableBufferPointer<UnsafeRawBufferPointer>.allocate(capacity: 4096)
		let headers = UnsafeMutableRawPointer.allocate(byteCount: Wire.headerSize * 4096, alignment: 8)
		defer {
			chunks.deallocate()
			headers.deallocate()
		}

		while true {
			condition.lock()
			while running && pendingStatistics == nil && (pending == nil || dirty.isEmpty) {
				condition.wait()
			}
			if running, let visible = pendingStatistics {
				pendingStatistics = nil
				condition.unlock()
				do {
					try stream.writeHeader { StatisticsMessage(visible: visible).encode(into: $0) }
				} catch {
					fail(error)
					return
				}
				continue
			}
			guard running, let frame = pending else {
				condition.unlock()
				return
			}
			pending = nil
			let fraction = dirty.dirtyFraction
			let rects = fraction > Self.fullFrameThreshold
				? [PixelRect(x: 0, y: 0, width: width, height: height)]
				: dirty.rectangles()
			dirty.removeAll()
			condition.unlock()

			guard CVPixelBufferGetWidth(frame.pixelBuffer) == width, CVPixelBufferGetHeight(frame.pixelBuffer) == height else {
				Log.capture.error("Dropping frame of unexpected size \(CVPixelBufferGetWidth(frame.pixelBuffer), privacy: .public)×\(CVPixelBufferGetHeight(frame.pixelBuffer), privacy: .public)")
				continue
			}

			do {
				try send(frame, rects: rects, chunks: &chunks, headers: headers)
			} catch {
				fail(error)
				return
			}
		}
	}

	private func send(_ frame: CapturedFrame, rects: [PixelRect], chunks: inout UnsafeMutableBufferPointer<UnsafeRawBufferPointer>, headers: UnsafeMutableRawPointer) throws {
		let pixelBuffer = frame.pixelBuffer
		CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
		let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

		// Worst case: one chunk per rectangle header plus one per row.
		let needed = 1 + rects.reduce(0) { $0 + 1 + $1.height }
		if needed > chunks.count {
			chunks.deallocate()
			chunks = .allocate(capacity: needed)
		}
		let headerSlots = 1 + rects.count
		let headerBytes = headerSlots > 4096 ? UnsafeMutableRawPointer.allocate(byteCount: headerSlots * Wire.headerSize, alignment: 8) : headers
		defer { if headerBytes != headers { headerBytes.deallocate() } }

		let frameID = nextFrameID
		nextFrameID += 1
		FrameBeginMessage(frameID: frameID, captureTime: frame.captureTime, rectCount: UInt32(rects.count)).encode(into: headerBytes)
		var count = 0
		chunks[count] = UnsafeRawBufferPointer(start: headerBytes, count: Wire.headerSize)
		count += 1

		var payloadBytes = 0
		for (i, rect) in rects.enumerated() {
			let header = headerBytes + (i + 1) * Wire.headerSize
			let rowBytes = rect.width * 4
			RectMessage(x: UInt32(rect.x), y: UInt32(rect.y), width: UInt32(rect.width), height: UInt32(rect.height), byteCount: UInt32(rowBytes * rect.height)).encode(into: header)
			chunks[count] = UnsafeRawBufferPointer(start: header, count: Wire.headerSize)
			count += 1
			let origin = base + rect.y * bytesPerRow + rect.x * 4
			if rowBytes == bytesPerRow {
				chunks[count] = UnsafeRawBufferPointer(start: origin, count: rowBytes * rect.height)
				count += 1
			} else {
				for row in 0..<rect.height {
					chunks[count] = UnsafeRawBufferPointer(start: origin + row * bytesPerRow, count: rowBytes)
					count += 1
				}
			}
			payloadBytes += rowBytes * rect.height
		}

		inflight.record(frameID: frameID, captureTime: frame.captureTime)
		try stream.write(UnsafeBufferPointer(rebasing: chunks[0..<count]))
		stats.recordSent(bytes: payloadBytes + headerSlots * Wire.headerSize, rects: rects.count, coverage: Double(payloadBytes) / Double(width * height * 4))
	}

	private func ackLoop() {
		while true {
			do {
				let message = try stream.readHeader(ReceiverMessage.decode)
				switch message {
				case .presented(let presented):
					if let captureTime = inflight.take(upTo: presented.frameID) {
						let arrival = Double(HostClock.now &- captureTime) / 1e9
						stats.recordPresented(latency: arrival + Double(presented.glassOffsetMicros) / 1e6)
					}
				case .statistics(let statistics):
					onStatistics(statistics.visible)
				case .displayReport(let report):
					stats.recordDisplayReport(report)
				case .unknown:
					break
				}
			} catch {
				fail(error)
				return
			}
		}
	}

	private func fail(_ error: Error) {
		condition.lock()
		let wasRunning = running
		running = false
		condition.signal()
		condition.unlock()
		stream.close()
		if wasRunning {
			onClose(error)
		}
	}
}

/// A message from the receiver.
private enum ReceiverMessage {
	case presented(PresentedMessage)
	case statistics(StatisticsMessage)
	case displayReport(DisplayReportMessage)
	case unknown

	static func decode(_ p: UnsafeRawPointer) throws -> ReceiverMessage {
		switch MessageType(rawValue: WireHeader.type(p)) {
		case .presented: .presented(try PresentedMessage.decode(p))
		case .statistics: .statistics(try StatisticsMessage.decode(p))
		case .displayReport: .displayReport(try DisplayReportMessage.decode(p))
		default: .unknown
		}
	}
}

/// Capture times of frames sent but not yet acknowledged.
private final class InflightFrames {
	private let lock = NSLock()
	private var frames: [(id: UInt64, captureTime: UInt64)] = []

	func record(frameID: UInt64, captureTime: UInt64) {
		lock.lock()
		defer { lock.unlock() }
		frames.append((frameID, captureTime))
		if frames.count > 256 { frames.removeFirst(frames.count - 256) }
	}

	/// Removes every frame up to `frameID` and returns that frame's capture time.
	func take(upTo frameID: UInt64) -> UInt64? {
		lock.lock()
		defer { lock.unlock() }
		guard let index = frames.firstIndex(where: { $0.id == frameID }) else {
			frames.removeAll { $0.id < frameID }
			return nil
		}
		let captureTime = frames[index].captureTime
		frames.removeFirst(index + 1)
		return captureTime
	}
}
