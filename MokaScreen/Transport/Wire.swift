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
/// the receiver reports each frame it puts on glass with `presented`.
enum Wire {
	/// `"MKSC"` read as a little-endian word.
	static let magic: UInt32 = 0x4353_4B4D
	/// Bumped on any incompatible change; peers with different versions refuse each other.
	static let version: UInt32 = 1
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
	/// Sender host time (nanoseconds) at which the frame was captured. Only meaningful to the sender.
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

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.presented.rawValue, p, 0)
		WireHeader.store(frameID, p, 8)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> PresentedMessage {
		try WireHeader.expect(.presented, p)
		return PresentedMessage(frameID: WireHeader.load64(p, 8))
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
