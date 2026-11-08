// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// Memory that can hold one full display of pixels, received straight off the socket.
final class FrameSlot {
	let contents: UnsafeMutableRawPointer
	let capacity: Int
	/// The object that owns `contents` (an `MTLBuffer` in the app), kept alive with the slot.
	let owner: AnyObject

	init(contents: UnsafeMutableRawPointer, capacity: Int, owner: AnyObject) {
		self.contents = contents
		self.capacity = capacity
		self.owner = owner
	}
}

/// One rectangle of a received frame and where its pixels sit in the slot.
struct ReceivedRect {
	var x: Int
	var y: Int
	var width: Int
	var height: Int
	var offset: Int
}

/// A complete frame, ready to be applied to the display image.
struct ReceivedFrame {
	var frameID: UInt64
	var rects: [ReceivedRect]
	var slot: FrameSlot
	/// Host time (nanoseconds) at which the frame's last byte arrived.
	var receivedTime: UInt64
}

/// Where the reader puts frames. The renderer implements it; tests use plain memory.
protocol FrameSink: AnyObject {
	/// Prepares for a display of this size. Called once per connection, before any frame.
	func configure(width: Int, height: Int) throws
	/// Returns an empty slot, blocking while all are in use. Returns `nil` once the sink is shutting down.
	func acquireSlot() -> FrameSlot?
	/// Returns a slot without using it, after a read failed mid-frame.
	func releaseUnused(_ slot: FrameSlot)
	/// Hands over a complete frame. The sink returns its slot to the pool when done with it.
	func commit(_ frame: ReceivedFrame)
}

/// Reads one sender's stream and feeds complete frames to a ``FrameSink``.
///
/// Pixels are received directly into the sink's slots — in the app, GPU-visible buffers —
/// so the only copy on the receiving side is the GPU's blit into the display texture. That
/// blit costs ~0.1 ms for a full frame, which is why rectangles are not blitted while the
/// rest of their frame is still arriving.
final class FrameReceiver {
	private let stream: ByteStream
	private let sink: FrameSink
	private let stats: ReceiverStats
	private let onHello: (HelloMessage) -> Void
	private let onStatistics: (Bool) -> Void
	private let onClose: (Error) -> Void
	private let ackQueue = DispatchQueue(label: "com.gigarip.mokascreen.ack", qos: .userInteractive)
	private let ackLock = NSLock()
	private var latestPresented: UInt64 = 0
	private var ackScheduled = false

	/// - Parameters:
	///   - onHello: Called on the reader thread once the sender is accepted.
	///   - onStatistics: Called on the reader thread when the sender changes Show Statistics.
	///   - onClose: Called once on the reader thread when the stream ends or fails.
	init(stream: ByteStream, sink: FrameSink, stats: ReceiverStats, onHello: @escaping (HelloMessage) -> Void, onStatistics: @escaping (Bool) -> Void, onClose: @escaping (Error) -> Void) {
		self.stream = stream
		self.sink = sink
		self.stats = stats
		self.onHello = onHello
		self.onStatistics = onStatistics
		self.onClose = onClose
	}

	/// Starts the reader thread.
	func start() {
		let thread = Thread { [self] in
			do {
				try run()
			} catch {
				stream.close()
				onClose(error)
			}
		}
		thread.name = "MokaScreen.receive"
		thread.qualityOfService = .userInteractive
		thread.start()
	}

	/// Closes the stream; the reader thread then exits and reports through `onClose`.
	func stop() {
		stream.close()
	}

	/// Tells the sender that `frameID` reached the display. Acknowledgements are coalesced, so a
	/// slow write never queues more than one behind it. Thread-safe.
	func reportPresented(frameID: UInt64) {
		ackLock.lock()
		latestPresented = max(latestPresented, frameID)
		let schedule = !ackScheduled
		ackScheduled = true
		ackLock.unlock()
		guard schedule else { return }
		ackQueue.async { [self] in
			ackLock.lock()
			let frameID = latestPresented
			ackScheduled = false
			ackLock.unlock()
			try? stream.writeHeader { PresentedMessage(frameID: frameID).encode(into: $0) }
		}
	}

	/// Tells the sender to show or hide its statistics. Thread-safe; written on the queue that
	/// writes `presented`, so the two never interleave.
	func sendStatistics(visible: Bool) {
		ackQueue.async { [self] in
			try? stream.writeHeader { StatisticsMessage(visible: visible).encode(into: $0) }
		}
	}

	private func run() throws {
		let hello = try stream.readHeader(HelloMessage.decode)
		guard hello.pixelFormat == Wire.pixelFormatBGRA8, hello.colorSpace == Wire.colorSpaceDisplayP3,
		      (1...16_384).contains(hello.width), (1...16_384).contains(hello.height)
		else { throw WireError.unsupportedFormat }
		try sink.configure(width: Int(hello.width), height: Int(hello.height))
		try stream.writeHeader { HelloAckMessage().encode(into: $0) }
		onHello(hello)

		while true {
			let begin: FrameBeginMessage
			switch try stream.readHeader(SenderMessage.decode) {
			case .frameBegin(let message):
				begin = message
			case .statistics(let message):
				onStatistics(message.visible)
				continue
			case .unknown:
				continue
			}
			guard let slot = sink.acquireSlot() else { throw TransportError.closed }
			var committed = false
			defer { if !committed { sink.releaseUnused(slot) } }

			var rects: [ReceivedRect] = []
			rects.reserveCapacity(Int(min(begin.rectCount, 4096)))
			var offset = 0
			for _ in 0..<begin.rectCount {
				let rect = try stream.readHeader(RectMessage.decode)
				try rect.validate(displayWidth: hello.width, displayHeight: hello.height)
				let byteCount = Int(rect.byteCount)
				guard offset + byteCount <= slot.capacity else { throw WireError.frameTooLarge }
				try stream.read(into: slot.contents + offset, count: byteCount)
				rects.append(ReceivedRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height), offset: offset))
				offset += byteCount
			}
			stats.recordReceived(bytes: offset + Wire.headerSize * (1 + rects.count))
			committed = true
			sink.commit(ReceivedFrame(frameID: begin.frameID, rects: rects, slot: slot, receivedTime: HostClock.now))
		}
	}
}

/// A message from the sender between frames.
private enum SenderMessage {
	case frameBegin(FrameBeginMessage)
	case statistics(StatisticsMessage)
	case unknown

	static func decode(_ p: UnsafeRawPointer) throws -> SenderMessage {
		switch MessageType(rawValue: WireHeader.type(p)) {
		case .frameBegin: .frameBegin(try FrameBeginMessage.decode(p))
		case .statistics: .statistics(try StatisticsMessage.decode(p))
		// A rect outside a frame is a protocol error, not an unknown message.
		case .rect, .hello, .helloAck, .presented: throw WireError.unexpectedMessage(WireHeader.type(p))
		case nil: .unknown
		}
	}
}
