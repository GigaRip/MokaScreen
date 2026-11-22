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
/// second with its share of the delay and how evenly frames reach the glass. For Develop ›
/// Record Frame Timing the sender sends a `timingRequest`, and for its duration the receiver
/// answers every frame it draws with a `frameTiming`. The receiver sends a `clockPing` four
/// times a second and the sender answers each with a `clockPong`, from which the receiver
/// works out the difference between the two Macs' clocks. With keyboard and trackpad sharing
/// on, the receiver sends an `input` for every key, pointer movement, click and scroll made on
/// it while it shows the picture. A side ignores a
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
	case timingRequest = 9
	case frameTiming = 10
	case clockPing = 11
	case clockPong = 12
	case input = 13
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
/// Flags at offset 4: bit 0 Show Statistics, bit 1 Smooth Motion, bit 2 Fixed 120 Hz. Smooth
/// Motion's minimum delay in milliseconds at offset 8.
struct SettingsMessage: Equatable {
	var settings: SharedSettings

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.settings.rawValue, p, 0)
		WireHeader.store(UInt32(settings.showsStatistics ? 1 : 0) | UInt32(settings.smoothMotion ? 2 : 0) | UInt32(settings.fixedRefreshRate ? 4 : 0) | UInt32(settings.forwardsInput ? 8 : 0), p, 4)
		WireHeader.store(UInt32(clamping: settings.smoothMotionFloorMillis), p, 8)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> SettingsMessage {
		try WireHeader.expect(.settings, p)
		let flags = WireHeader.load32(p, 4)
		return SettingsMessage(settings: SharedSettings(
			showsStatistics: flags & 1 != 0,
			smoothMotion: flags & 2 != 0,
			fixedRefreshRate: flags & 4 != 0,
			smoothMotionFloorMillis: Int(min(WireHeader.load32(p, 8), 1000)),
			forwardsInput: flags & 8 != 0
		))
	}
}

/// Receiver → sender: one keyboard or trackpad event made on the display Mac, to be repeated on
/// the Mac you work on. See ``InputCapture`` and ``InputInjector``.
///
/// Layout: `kind` at 4, `detail` at 5, `code` at 6, `flags` at 8, `x` and `y` at 16 and 20,
/// `pointX` and `pointY` at 24 and 26, `lineX` and `lineY` at 28 and 29, `phase` at 30,
/// `momentumPhase` at 31.
struct InputMessage: Equatable {
	enum Kind: UInt8 {
		case keyDown = 1
		case keyUp = 2
		/// A modifier key went down or up; `flags` is the state afterwards.
		case flagsChanged = 3
		/// The pointer moved by `x`, `y` points, y downwards.
		case pointerMoved = 4
		case buttonDown = 5
		case buttonUp = 6
		case scroll = 7
		/// The display Mac stopped forwarding: let go of every key and button still held.
		case releaseAll = 8
	}

	var kind: Kind
	/// Keys: 1 for an auto-repeat. Buttons: the click count. Scroll: 1 for a continuous
	/// (trackpad) scroll.
	var detail: UInt8 = 0
	/// The virtual key code, or the mouse button number.
	var code: UInt16 = 0
	/// `CGEventFlags` at the time of the event.
	var flags: UInt64 = 0
	/// Pointer movement in points; for a scroll, the fixed-point deltas.
	var x: Float32 = 0
	var y: Float32 = 0
	/// Scroll deltas in pixels and in lines.
	var pointX: Int16 = 0
	var pointY: Int16 = 0
	var lineX: Int8 = 0
	var lineY: Int8 = 0
	/// `CGScrollPhase` and `CGMomentumScrollPhase`, which carry a trackpad scroll's start, end
	/// and coasting.
	var phase: UInt8 = 0
	var momentumPhase: UInt8 = 0

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.input.rawValue, p, 0)
		WireHeader.store(UInt32(kind.rawValue) | UInt32(detail) << 8 | UInt32(code) << 16, p, 4)
		WireHeader.store(flags, p, 8)
		WireHeader.store(x.bitPattern, p, 16)
		WireHeader.store(y.bitPattern, p, 20)
		WireHeader.store(UInt32(UInt16(bitPattern: pointX)) | UInt32(UInt16(bitPattern: pointY)) << 16, p, 24)
		WireHeader.store(UInt32(UInt8(bitPattern: lineX)) | UInt32(UInt8(bitPattern: lineY)) << 8 | UInt32(phase) << 16 | UInt32(momentumPhase) << 24, p, 28)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> InputMessage {
		try WireHeader.expect(.input, p)
		let head = WireHeader.load32(p, 4)
		guard let kind = Kind(rawValue: UInt8(truncatingIfNeeded: head)) else { throw WireError.unexpectedMessage(MessageType.input.rawValue) }
		let points = WireHeader.load32(p, 24)
		let tail = WireHeader.load32(p, 28)
		return InputMessage(
			kind: kind,
			detail: UInt8(truncatingIfNeeded: head >> 8),
			code: UInt16(truncatingIfNeeded: head >> 16),
			flags: WireHeader.load64(p, 8),
			x: Float32(bitPattern: WireHeader.load32(p, 16)),
			y: Float32(bitPattern: WireHeader.load32(p, 20)),
			pointX: Int16(bitPattern: UInt16(truncatingIfNeeded: points)),
			pointY: Int16(bitPattern: UInt16(truncatingIfNeeded: points >> 16)),
			lineX: Int8(bitPattern: UInt8(truncatingIfNeeded: tail)),
			lineY: Int8(bitPattern: UInt8(truncatingIfNeeded: tail >> 8)),
			phase: UInt8(truncatingIfNeeded: tail >> 16),
			momentumPhase: UInt8(truncatingIfNeeded: tail >> 24)
		)
	}
}

/// Sender → receiver: report how each frame reaches the glass, with one ``FrameTimingMessage``
/// per frame, for the next `durationMillis`.
struct TimingRequestMessage: Equatable {
	var durationMillis: UInt32

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.timingRequest.rawValue, p, 0)
		WireHeader.store(durationMillis, p, 4)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> TimingRequestMessage {
		try WireHeader.expect(.timingRequest, p)
		return TimingRequestMessage(durationMillis: WireHeader.load32(p, 4))
	}
}

/// Receiver → sender, while a timing request lasts: when one frame arrived, was drawn, and
/// reached the glass, on the display Mac's clock.
///
/// Layout: flags at 4 (bits 0–15 `drawnTogether`, bits 16–30 `targetAfterDrawTenths`, bit 31
/// `paced`), `frameID` at 8, `drawTime` at 16, `receivedBeforeDrawMicros` at 24,
/// `glassAfterDrawMicros` at 28.
struct FrameTimingMessage: Equatable, BitwiseCopyable {
	var frameID: UInt64
	/// Host nanoseconds on the display Mac when the draw that applied this frame was encoded.
	var drawTime: UInt64
	/// Microseconds from the frame's last byte arriving to that draw.
	var receivedBeforeDrawMicros: UInt32
	/// Microseconds from that draw to the glass; −1 when the drawable was never shown.
	var glassAfterDrawMicros: Int32
	/// Frames applied by the same draw. Above 1, the earlier ones never reached the glass alone.
	var drawnTogether: UInt16
	/// Whether Smooth Motion held the draw for a paced glass time.
	var paced: Bool
	/// When Smooth Motion asked for the drawable to be presented, in tenths of a millisecond after
	/// the draw, up to 3.2 s; zero when presented at once.
	var targetAfterDrawTenths: UInt16 = 0

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.frameTiming.rawValue, p, 0)
		WireHeader.store(UInt32(drawnTogether) | UInt32(min(targetAfterDrawTenths, 0x7FFF)) << 16 | (paced ? 1 << 31 : 0), p, 4)
		WireHeader.store(frameID, p, 8)
		WireHeader.store(drawTime, p, 16)
		WireHeader.store(receivedBeforeDrawMicros, p, 24)
		WireHeader.store(UInt32(bitPattern: glassAfterDrawMicros), p, 28)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> FrameTimingMessage {
		try WireHeader.expect(.frameTiming, p)
		let flags = WireHeader.load32(p, 4)
		return FrameTimingMessage(
			frameID: WireHeader.load64(p, 8),
			drawTime: WireHeader.load64(p, 16),
			receivedBeforeDrawMicros: WireHeader.load32(p, 24),
			glassAfterDrawMicros: Int32(bitPattern: WireHeader.load32(p, 28)),
			drawnTogether: UInt16(truncatingIfNeeded: flags),
			paced: flags & (1 << 31) != 0,
			targetAfterDrawTenths: UInt16((flags >> 16) & 0x7FFF)
		)
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
	/// The round trip of the ping the clock offset came from, in microseconds; zero while the
	/// clocks are not synchronized.
	var clockRoundTripMicros: UInt32

	init(unevenFrames: UInt32, comparedFrames: UInt32, pacingMicros: UInt32, intervalMillis: UInt32, clockRoundTripMicros: UInt32 = 0) {
		self.unevenFrames = unevenFrames
		self.comparedFrames = comparedFrames
		self.pacingMicros = pacingMicros
		self.intervalMillis = intervalMillis
		self.clockRoundTripMicros = clockRoundTripMicros
	}

	init(_ snapshot: ReceiverSnapshot) {
		self.init(
			unevenFrames: UInt32(clamping: snapshot.unevenFrames),
			comparedFrames: UInt32(clamping: snapshot.comparedFrames),
			pacingMicros: UInt32(clamping: Int((snapshot.pacing * 1000).rounded())),
			intervalMillis: UInt32(clamping: Int((snapshot.interval * 1000).rounded())),
			clockRoundTripMicros: UInt32(clamping: snapshot.clockRoundTripMicros)
		)
	}

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.paceReport.rawValue, p, 0)
		WireHeader.store(unevenFrames, p, 4)
		WireHeader.store(comparedFrames, p, 8)
		WireHeader.store(pacingMicros, p, 12)
		WireHeader.store(intervalMillis, p, 16)
		WireHeader.store(clockRoundTripMicros, p, 20)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> PaceReportMessage {
		try WireHeader.expect(.paceReport, p)
		return PaceReportMessage(
			unevenFrames: WireHeader.load32(p, 4),
			comparedFrames: WireHeader.load32(p, 8),
			pacingMicros: WireHeader.load32(p, 12),
			intervalMillis: WireHeader.load32(p, 16),
			clockRoundTripMicros: WireHeader.load32(p, 20)
		)
	}
}

/// Receiver → sender, four times a second: asks for the sender's clock. See ``ClockOffsetEstimator``.
struct ClockPingMessage: Equatable {
	/// The receiver's host time when it sent the ping, in nanoseconds.
	var sentTime: UInt64

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.clockPing.rawValue, p, 0)
		WireHeader.store(sentTime, p, 8)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> ClockPingMessage {
		try WireHeader.expect(.clockPing, p)
		return ClockPingMessage(sentTime: WireHeader.load64(p, 8))
	}
}

/// Sender → receiver: answers a `clockPing`.
struct ClockPongMessage: Equatable {
	/// The ping's `sentTime`, returned unchanged, on the receiver's clock.
	var pingSentTime: UInt64
	/// The sender's host time when the ping arrived and when this reply was written, in
	/// nanoseconds. The time between them is the sender's own and is left out of the round trip.
	var receivedTime: UInt64
	var sentTime: UInt64

	func encode(into p: UnsafeMutableRawPointer) {
		WireHeader.clear(p)
		WireHeader.store(MessageType.clockPong.rawValue, p, 0)
		WireHeader.store(pingSentTime, p, 8)
		WireHeader.store(receivedTime, p, 16)
		WireHeader.store(sentTime, p, 24)
	}

	static func decode(_ p: UnsafeRawPointer) throws -> ClockPongMessage {
		try WireHeader.expect(.clockPong, p)
		return ClockPongMessage(pingSentTime: WireHeader.load64(p, 8), receivedTime: WireHeader.load64(p, 16), sentTime: WireHeader.load64(p, 24))
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
