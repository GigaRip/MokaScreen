// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// Constants of the MokaScreen wire protocol.
///
/// Every message begins with a fixed 32-byte header whose first word is its
/// ``MessageType``. All integers are little-endian. A `rect` header is followed
/// by `byteCount` bytes of pixel payload; no other message carries a payload.
///
/// A session is: sender → `hello`, receiver → `helloAck`, then the sender
/// streams frames (`frameBegin` followed by exactly `rectCount` × `rect`) while
/// the receiver reports each frame it puts on glass with `presented`. Either side
/// may send `settings` between frames to change the other's Show Statistics and
/// Smooth Motion settings; the sender sends its own right after the handshake.
/// While showing, the receiver sends a `displayReport` and a `paceReport` once a
/// second with its share of the delay and how evenly frames reach the glass. A side ignores a
/// header type it does not know, outside a frame, so a later message type that
/// carries no payload does not need a version change.
enum Wire {
	/// `"MKSC"` read as a little-endian word.
	static let magic: UInt32 = 0x4353_4B4D
	/// Bumped on any incompatible change; peers with different versions refuse each other.
	static let version: UInt32 = 2
	/// Size of every message header, in bytes.
	static let headerSize = 32
	/// TCP port the receiver listens on.
	static let port: UInt16 = 47_520
	/// Bonjour service type the receiver advertises.
	static let serviceType = "_mokascreen._tcp"
	/// The only pixel format on the wire today: 8-bit BGRA, premultiplied, opaque.
	static let pixelFormatBGRA8: UInt32 = 0x4247_5241
	/// Pixels are encoded in the Display P3 color space.
	static let colorSpaceDisplayP3: UInt32 = 1
}

/// The first word of every message header.
enum MessageType: UInt32 {
	case hello = 1
	case helloAck = 2
	case frameBegin = 3
	case rect = 4
	case presented = 5
	case settings = 6
	case displayReport = 7
	case paceReport = 8
}

/// Errors raised while decoding the wire protocol.
enum WireError: Error, CustomStringConvertible {
	case unexpectedMessage(UInt32)
	case badMagic
	case versionMismatch(UInt32)
	case unsupportedFormat
	case rectOutOfBounds
	case payloadMismatch
	case frameTooLarge

	var description: String {
		switch self {
		case .unexpectedMessage(let type): "Unexpected message type \(type)"
		case .badMagic: "The peer is not MokaScreen"
		case .versionMismatch(let version): "The other Mac runs an incompatible MokaScreen (protocol \(version), this Mac \(Wire.version))"
		case .unsupportedFormat: "Unsupported pixel format"
		case .rectOutOfBounds: "Update rectangle outside the display"
		case .payloadMismatch: "Update payload size does not match its rectangle"
		case .frameTooLarge: "Frame payload exceeds one full display"
		}
	}
}

/// Pixel payload encodings. Only `raw` exists today; the field reserves room for LZ4.
enum RectEncoding: UInt32 {
	case raw = 0
}

/// Sender → receiver: opens a session and describes the display.
struct HelloMessage: Equatable {
	var width: UInt32
	var height: UInt32
	var pixelFormat: UInt32 = Wire.pixelFormatBGRA8
	var colorSpace: UInt32 = Wire.colorSpaceDisplayP3
	var version: UInt32 = Wire.version

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.hello.rawValue, p, 0)
		WireHeader.store(Wire.magic, p, 4)
		WireHeader.store(version, p, 8)
		WireHeader.store(width, p, 12)
		WireHeader.store(height, p, 16)
		WireHeader.store(pixelFormat, p, 20)
		WireHeader.store(colorSpace, p, 24)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> HelloMessage {
		try WireHeader.expect(.hello, p)
		guard WireHeader.load32(p, 4) == Wire.magic else { throw WireError.badMagic }
		let message = HelloMessage(
			width: WireHeader.load32(p, 12),
			height: WireHeader.load32(p, 16),
			pixelFormat: WireHeader.load32(p, 20),
			colorSpace: WireHeader.load32(p, 24),
			version: WireHeader.load32(p, 8)
		)
		guard message.version == Wire.version else { throw WireError.versionMismatch(message.version) }
		return message
	}
}

/// Receiver → sender: accepts the session.
struct HelloAckMessage: Equatable {
	var version: UInt32 = Wire.version

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.helloAck.rawValue, p, 0)
		WireHeader.store(Wire.magic, p, 4)
		WireHeader.store(version, p, 8)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> HelloAckMessage {
		try WireHeader.expect(.helloAck, p)
		guard WireHeader.load32(p, 4) == Wire.magic else { throw WireError.badMagic }
		let version = WireHeader.load32(p, 8)
		guard version == Wire.version else { throw WireError.versionMismatch(version) }
		return HelloAckMessage(version: version)
	}
}

/// Sender → receiver: starts a frame made of `rectCount` disjoint rectangles.
struct FrameBeginMessage: Equatable {
	var frameID: UInt64
	/// Sender host time (nanoseconds) at which the frame was captured. The two Macs' clocks are
	/// unrelated, so the receiver uses only differences between these.
	var captureTime: UInt64
	var rectCount: UInt32

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.frameBegin.rawValue, p, 0)
		WireHeader.store(rectCount, p, 4)
		WireHeader.store(frameID, p, 8)
		WireHeader.store(captureTime, p, 16)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> FrameBeginMessage {
		try WireHeader.expect(.frameBegin, p)
		return FrameBeginMessage(
			frameID: WireHeader.load64(p, 8),
			captureTime: WireHeader.load64(p, 16),
			rectCount: WireHeader.load32(p, 4)
		)
	}
}

/// Sender → receiver: one updated rectangle, followed by its pixel payload.
///
/// A raw payload is `height` rows of `width × 4` bytes with no row padding.
struct RectMessage: Equatable {
	var x: UInt32
	var y: UInt32
	var width: UInt32
	var height: UInt32
	var encoding: UInt32 = RectEncoding.raw.rawValue
	var byteCount: UInt32

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.rect.rawValue, p, 0)
		WireHeader.store(x, p, 4)
		WireHeader.store(y, p, 8)
		WireHeader.store(width, p, 12)
		WireHeader.store(height, p, 16)
		WireHeader.store(encoding, p, 20)
		WireHeader.store(byteCount, p, 24)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> RectMessage {
		try WireHeader.expect(.rect, p)
		return RectMessage(
			x: WireHeader.load32(p, 4),
			y: WireHeader.load32(p, 8),
			width: WireHeader.load32(p, 12),
			height: WireHeader.load32(p, 16),
			encoding: WireHeader.load32(p, 20),
			byteCount: WireHeader.load32(p, 24)
		)
	}

	/// Checks the rectangle lies within a `displayWidth × displayHeight` display and that a raw
	/// payload has exactly the size its rectangle implies.
	func validate(displayWidth: UInt32, displayHeight: UInt32) throws {
		guard width > 0, height > 0,
		      x < displayWidth, y < displayHeight,
		      width <= displayWidth - x, height <= displayHeight - y
		else { throw WireError.rectOutOfBounds }
		guard encoding == RectEncoding.raw.rawValue else { throw WireError.unsupportedFormat }
		guard UInt64(byteCount) == UInt64(width) * UInt64(height) * 4 else { throw WireError.payloadMismatch }
	}
}

/// Receiver → sender: the frame with this ID (and every earlier one) is on glass.
struct PresentedMessage: Equatable {
	var frameID: UInt64
	/// The frame's glass time minus the time this message was written, on the display Mac's
	/// clock, in microseconds. macOS can call a drawable's presented handler before the frame's
	/// `presentedTime`, so the sender adds this to the acknowledgement's arrival to time capture
	/// → glass without a shared clock. Zero from 0.1.12 and earlier.
	var glassOffsetMicros: Int32 = 0

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.presented.rawValue, p, 0)
		WireHeader.store(UInt32(bitPattern: glassOffsetMicros), p, 4)
		WireHeader.store(frameID, p, 8)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> PresentedMessage {
		try WireHeader.expect(.presented, p)
		return PresentedMessage(frameID: WireHeader.load64(p, 8), glassOffsetMicros: Int32(bitPattern: WireHeader.load32(p, 4)))
	}
}

/// Either direction: the settings both Macs share, so changing one on either Mac changes both.
/// Flags at offset 4: bit 0 Show Statistics, bit 1 Smooth Motion, bit 2 Fixed 120 Hz.
struct SettingsMessage: Equatable {
	var settings: SharedSettings

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.settings.rawValue, p, 0)
		WireHeader.store(UInt32(settings.showsStatistics ? 1 : 0) | UInt32(settings.smoothMotion ? 2 : 0) | UInt32(settings.fixedRefreshRate ? 4 : 0), p, 4)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> SettingsMessage {
		try WireHeader.expect(.settings, p)
		let flags = WireHeader.load32(p, 4)
		return SettingsMessage(settings: SharedSettings(showsStatistics: flags & 1 != 0, smoothMotion: flags & 2 != 0, fixedRefreshRate: flags & 4 != 0))
	}
}

/// Receiver → sender, once a second while showing: how evenly frames reached the glass.
struct PaceReportMessage: Equatable {
	/// Consecutive frames whose spacing on the glass differed from their spacing at capture by
	/// more than half a refresh, over `intervalMillis`.
	var unevenFrames: UInt32
	/// Consecutive frames compared over `intervalMillis`: those captured less than three
	/// refreshes apart, so a pause in the picture is not counted as unevenness.
	var comparedFrames: UInt32
	/// Smooth Motion's current delay, in microseconds; zero while it is off.
	var pacingMicros: UInt32
	var intervalMillis: UInt32

	init(unevenFrames: UInt32, comparedFrames: UInt32, pacingMicros: UInt32, intervalMillis: UInt32) {
		self.unevenFrames = unevenFrames
		self.comparedFrames = comparedFrames
		self.pacingMicros = pacingMicros
		self.intervalMillis = intervalMillis
	}

	init(_ snapshot: ReceiverSnapshot) {
		self.init(
			unevenFrames: UInt32(clamping: snapshot.unevenFrames),
			comparedFrames: UInt32(clamping: snapshot.comparedFrames),
			pacingMicros: UInt32(clamping: Int((snapshot.pacing * 1000).rounded())),
			intervalMillis: UInt32(clamping: Int((snapshot.interval * 1000).rounded()))
		)
	}

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.paceReport.rawValue, p, 0)
		WireHeader.store(unevenFrames, p, 4)
		WireHeader.store(comparedFrames, p, 8)
		WireHeader.store(pacingMicros, p, 12)
		WireHeader.store(intervalMillis, p, 16)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> PaceReportMessage {
		try WireHeader.expect(.paceReport, p)
		return PaceReportMessage(
			unevenFrames: WireHeader.load32(p, 4),
			comparedFrames: WireHeader.load32(p, 8),
			pacingMicros: WireHeader.load32(p, 12),
			intervalMillis: WireHeader.load32(p, 16)
		)
	}
}

/// Receiver → sender, once a second while showing: the display Mac's share of the delay, so
/// the Mac you work on can show the whole breakdown. The display Mac cannot show it itself:
/// anything drawn over the picture makes WindowServer composite it, adding a refresh of delay.
struct DisplayReportMessage: Equatable {
	/// Rolling median and 99th percentile from the last byte of a frame arriving to it being on
	/// glass, in microseconds.
	var delayP50Micros: UInt32
	var delayP99Micros: UInt32
	/// Frames received and presented over `intervalMillis`.
	var receivedFrames: UInt32
	var presentedFrames: UInt32
	var intervalMillis: UInt32
	/// Drawables presented over `intervalMillis`. Zero from 0.1.10 and earlier, which leave the
	/// field clear.
	var draws: UInt32
	/// Rolling median from the last byte of a frame arriving to its draw starting, in microseconds.
	var waitP50Micros: UInt32

	init(delayP50Micros: UInt32, delayP99Micros: UInt32, receivedFrames: UInt32, presentedFrames: UInt32, intervalMillis: UInt32, draws: UInt32 = 0, waitP50Micros: UInt32 = 0) {
		self.delayP50Micros = delayP50Micros
		self.delayP99Micros = delayP99Micros
		self.receivedFrames = receivedFrames
		self.presentedFrames = presentedFrames
		self.intervalMillis = intervalMillis
		self.draws = draws
		self.waitP50Micros = waitP50Micros
	}

	init(_ snapshot: ReceiverSnapshot) {
		self.init(
			delayP50Micros: UInt32(clamping: Int((snapshot.recentDelay * 1000).rounded())),
			delayP99Micros: UInt32(clamping: Int((snapshot.recentDelayP99 * 1000).rounded())),
			receivedFrames: UInt32(clamping: snapshot.receivedFrames),
			presentedFrames: UInt32(clamping: snapshot.presentedFrames),
			intervalMillis: UInt32(clamping: Int((snapshot.interval * 1000).rounded())),
			draws: UInt32(clamping: snapshot.draws),
			waitP50Micros: UInt32(clamping: Int((snapshot.recentWait * 1000).rounded()))
		)
	}

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.displayReport.rawValue, p, 0)
		WireHeader.store(delayP50Micros, p, 4)
		WireHeader.store(delayP99Micros, p, 8)
		WireHeader.store(receivedFrames, p, 12)
		WireHeader.store(presentedFrames, p, 16)
		WireHeader.store(intervalMillis, p, 20)
		WireHeader.store(draws, p, 24)
		WireHeader.store(waitP50Micros, p, 28)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> DisplayReportMessage {
		try WireHeader.expect(.displayReport, p)
		return DisplayReportMessage(
			delayP50Micros: WireHeader.load32(p, 4),
			delayP99Micros: WireHeader.load32(p, 8),
			receivedFrames: WireHeader.load32(p, 12),
			presentedFrames: WireHeader.load32(p, 16),
			intervalMillis: WireHeader.load32(p, 20),
			draws: WireHeader.load32(p, 24),
			waitP50Micros: WireHeader.load32(p, 28)
		)
	}
}

/// Byte-level helpers for the fixed-size header. Unaligned loads keep decoding
/// independent of where a header lands in a receive buffer.
enum WireHeader {
	static func clear(_ p: UnsafeMutableRawPointer) {
		p.initializeMemory(as: UInt8.self, repeating: 0, count: Wire.headerSize)
	}

	static func store(_ value: UInt32, _ p: UnsafeMutableRawPointer, _ offset: Int) {
		p.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
	}

	static func store(_ value: UInt64, _ p: UnsafeMutableRawPointer, _ offset: Int) {
		p.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
	}

	static func load32(_ p: UnsafeRawPointer, _ offset: Int) -> UInt32 {
		UInt32(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
	}

	static func load64(_ p: UnsafeRawPointer, _ offset: Int) -> UInt64 {
		UInt64(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
	}

	static func type(_ p: UnsafeRawPointer) -> UInt32 {
		load32(p, 0)
	}

	static func expect(_ type: MessageType, _ p: UnsafeRawPointer) throws {
		let actual = load32(p, 0)
		guard actual == type.rawValue else { throw WireError.unexpectedMessage(actual) }
	}
}
