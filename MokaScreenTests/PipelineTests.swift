// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MokaScreen

/// A ``FrameSink`` that applies frames to a plain in-memory image.
private final class MemorySink: FrameSink {
	private(set) var width = 0
	private(set) var height = 0
	private(set) var image: [UInt8] = []
	private var free: [FrameSlot] = []
	private let lock = NSLock()
	private let available = DispatchSemaphore(value: 0)
	private let committed = DispatchSemaphore(value: 0)
	private(set) var lastFrameID: UInt64 = 0
	var onCommit: ((UInt64) -> Void)?

	func configure(width: Int, height: Int) throws {
		self.width = width
		self.height = height
		image = Array(repeating: 0, count: width * height * 4)
		for _ in 0..<3 {
			let memory = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
			free.append(FrameSlot(contents: memory, capacity: width * height * 4, owner: NSObject()))
			available.signal()
		}
	}

	func acquireSlot() -> FrameSlot? {
		available.wait()
		return lock.withLock { free.popLast() }
	}

	func releaseUnused(_ slot: FrameSlot) {
		lock.withLock { free.append(slot) }
		available.signal()
	}

	func commit(_ frame: ReceivedFrame) {
		lock.withLock {
			for rect in frame.rects {
				let source = frame.slot.contents + rect.offset
				image.withUnsafeMutableBytes { image in
					for row in 0..<rect.height {
						let destination = image.baseAddress! + ((rect.y + row) * width + rect.x) * 4
						destination.copyMemory(from: source + row * rect.width * 4, byteCount: rect.width * 4)
					}
				}
			}
			lastFrameID = frame.frameID
			free.append(frame.slot)
		}
		available.signal()
		onCommit?(frame.frameID)
		committed.signal()
	}

	func waitForFrame(timeout: TimeInterval = 5) -> Bool {
		committed.wait(timeout: .now() + timeout) == .success
	}

	func snapshot() -> [UInt8] {
		lock.withLock { image }
	}
}

private func makeFrame(width: Int, height: Int, fill: (Int, Int) -> UInt32, dirty: [CGRect]) throws -> CapturedFrame {
	var pixelBuffer: CVPixelBuffer?
	let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
	guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
		throw TestError.setup
	}
	CVPixelBufferLockBaseAddress(pixelBuffer, [])
	let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
	let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
	for y in 0..<height {
		let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
		for x in 0..<width { row[x] = fill(x, y) }
	}
	CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

	var format: CMVideoFormatDescription?
	CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
	var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
	var sampleBuffer: CMSampleBuffer?
	CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
	return CapturedFrame(sampleBuffer: sampleBuffer!, pixelBuffer: pixelBuffer, dirtyRects: dirty, captureTime: HostClock.now)
}

private func expectedImage(width: Int, height: Int, fill: (Int, Int) -> UInt32) -> [UInt8] {
	var image = [UInt8](repeating: 0, count: width * height * 4)
	image.withUnsafeMutableBytes { raw in
		let pixels = raw.bindMemory(to: UInt32.self)
		for y in 0..<height {
			for x in 0..<width { pixels[y * width + x] = fill(x, y) }
		}
	}
	return image
}

private enum TestError: Error { case setup }

/// Show Statistics values one side received, in order.
private final class StatisticsLog: @unchecked Sendable {
	private let lock = NSLock()
	private let arrived = DispatchSemaphore(value: 0)
	private var values: [Bool] = []

	func record(_ visible: Bool) {
		lock.withLock { values.append(visible) }
		arrived.signal()
	}

	/// The next value received, or nil after a timeout.
	func next() -> Bool? {
		guard arrived.wait(timeout: .now() + 5) == .success else { return nil }
		return lock.withLock { values.removeFirst() }
	}
}

/// A connected sender/receiver pair over loopback TCP.
private struct Loopback {
	let sink = MemorySink()
	let receiver: FrameReceiver
	let sender: FrameSender
	let senderStats = SenderStats()
	let listener: TCPListener
	/// Show Statistics values each side heard from the other.
	let senderHeard = StatisticsLog()
	let receiverHeard = StatisticsLog()

	init(width: Int, height: Int, showsStatistics: Bool = false) throws {
		let port = UInt16.random(in: 48_000...58_000)
		let accepted = DispatchSemaphore(value: 0)
		var serverStream: TCPStream?
		listener = try TCPListener(port: port, scope: .loopback) { stream in
			serverStream = stream
			accepted.signal()
		}
		let client = try TCPStream.connect(to: SocketAddress.resolve(host: "127.0.0.1", port: port)[0])
		guard accepted.wait(timeout: .now() + 5) == .success, let serverStream else { throw TestError.setup }

		let receiverStats = ReceiverStats()
		let hello = DispatchSemaphore(value: 0)
		receiver = FrameReceiver(stream: serverStream, sink: sink, stats: receiverStats, onHello: { _ in hello.signal() }, onStatistics: { [receiverHeard] in receiverHeard.record($0) }, onClose: { _ in })
		receiver.start()
		try client.writeHeader { HelloMessage(width: UInt32(width), height: UInt32(height)).encode(into: $0) }
		_ = try client.readHeader(HelloAckMessage.decode)
		guard hello.wait(timeout: .now() + 5) == .success else { throw TestError.setup }

		sender = FrameSender(stream: client, width: width, height: height, stats: senderStats, showsStatistics: showsStatistics, onStatistics: { [senderHeard] in senderHeard.record($0) }) { _ in }
		let receiver = receiver
		sink.onCommit = { receiver.reportPresented(frameID: $0) }
	}

	func close() {
		sender.stop()
		receiver.stop()
		listener.stop()
	}
}

struct PipelineTests {
	// An odd width makes CoreVideo pad each row, exercising the row-by-row gather path.
	@Test(arguments: [(641, 401), (640, 400)])
	func framesArriveBitExact(size: (Int, Int)) throws {
		let (width, height) = size
		let loopback = try Loopback(width: width, height: height)
		defer { loopback.close() }

		let first: (Int, Int) -> UInt32 = { x, y in UInt32(truncatingIfNeeded: x &* 2654435761 ^ y &* 40503) | 0xFF00_0000 }
		loopback.sender.submit(try makeFrame(width: width, height: height, fill: first, dirty: []))
		#expect(loopback.sink.waitForFrame())
		#expect(loopback.sink.snapshot() == expectedImage(width: width, height: height, fill: first))

		let changed = CGRect(x: 100, y: 50, width: 70, height: 33)
		let second: (Int, Int) -> UInt32 = { x, y in
			changed.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) ? 0xFF12_3456 : first(x, y)
		}
		loopback.sender.submit(try makeFrame(width: width, height: height, fill: second, dirty: [changed]))
		#expect(loopback.sink.waitForFrame())
		#expect(loopback.sink.snapshot() == expectedImage(width: width, height: height, fill: second))

		// The presented acknowledgement travels back and becomes a latency sample.
		Thread.sleep(forTimeInterval: 0.2)
		let stats = loopback.senderStats.drain()
		#expect(stats.sentFrames == 2)
		#expect(stats.latencyP50 > 0)
		#expect(stats.maxCoverage == 1)
		#expect(stats.meanCoverage < 1)
	}

	@Test func statisticsSettingTravelsBothWaysBetweenFrames() throws {
		let (width, height) = (64, 48)
		let loopback = try Loopback(width: width, height: height, showsStatistics: true)
		defer { loopback.close() }
		let fill: (Int, Int) -> UInt32 = { x, y in UInt32(truncatingIfNeeded: x &* 31 ^ y) | 0xFF00_0000 }
		let frame = try makeFrame(width: width, height: height, fill: fill, dirty: [])

		// The sender's own setting reaches the receiver as soon as it connects.
		#expect(loopback.receiverHeard.next() == true)
		loopback.sender.submit(frame)
		#expect(loopback.sink.waitForFrame())

		loopback.receiver.sendStatistics(visible: false)
		#expect(loopback.senderHeard.next() == false)
		loopback.sender.sendStatistics(visible: true)
		#expect(loopback.receiverHeard.next() == true)

		// Frames still arrive intact after messages between them in both directions.
		loopback.sender.submit(try makeFrame(width: width, height: height, fill: fill, dirty: [CGRect(x: 0, y: 0, width: width, height: height)]))
		#expect(loopback.sink.waitForFrame())
		#expect(loopback.sink.snapshot() == expectedImage(width: width, height: height, fill: fill))
	}

	@Test func displayReportReachesTheSenderStatistics() throws {
		let loopback = try Loopback(width: 64, height: 48)
		defer { loopback.close() }
		var snapshot = ReceiverSnapshot()
		snapshot.interval = 1
		snapshot.presentedFrames = 120
		snapshot.recentDelay = 15.5
		snapshot.recentDelayP99 = 19
		loopback.receiver.sendReport(snapshot)

		var stats = SenderSnapshot()
		for _ in 0..<50 where stats.displayDelay == 0 {
			Thread.sleep(forTimeInterval: 0.02)
			stats = loopback.senderStats.drain()
		}
		#expect(stats.displayDelay == 15.5)
		#expect(stats.displayDelayP99 == 19)
	}

	@Test func fullFrameThroughputOverLoopback() throws {
		let (width, height) = (3456, 2234)
		let loopback = try Loopback(width: width, height: height)
		defer { loopback.close() }
		let frame = try makeFrame(width: width, height: height, fill: { x, y in UInt32(truncatingIfNeeded: x ^ y) }, dirty: [CGRect(x: 0, y: 0, width: width, height: height)])

		let count = 120
		let start = Date()
		for _ in 0..<count {
			loopback.sender.submit(frame)
			#expect(loopback.sink.waitForFrame())
		}
		let elapsed = Date().timeIntervalSince(start)
		let gbps = Double(count * width * height * 4 * 8) / elapsed / 1e9
		print(String(format: "Loopback: %d full frames in %.3f s — %.1f ms/frame, %.1f Gbps", count, elapsed, elapsed / Double(count) * 1000, gbps))
		#expect(elapsed / Double(count) < 1.0 / 60)
	}
}
