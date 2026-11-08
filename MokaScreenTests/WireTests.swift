// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Testing
@testable import MokaScreen

struct WireTests {
	private func roundTrip<T>(_ encode: (UnsafeMutableRawPointer) -> Void, _ decode: (UnsafeRawPointer) throws -> T) throws -> T {
		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Wire.headerSize, alignment: 8)
		defer { buffer.deallocate() }
		encode(buffer)
		return try decode(buffer)
	}

	@Test(arguments: [true, false])
	func statisticsRoundTrips(visible: Bool) throws {
		let message = StatisticsMessage(visible: visible)
		#expect(try roundTrip(message.encode, StatisticsMessage.decode) == message)
	}

	@Test func displayReportRoundTrips() throws {
		let report = DisplayReportMessage(delayP50Micros: 15_480, delayP99Micros: 19_020, receivedFrames: 118, presentedFrames: 120, intervalMillis: 1003, draws: 61, waitP50Micros: 6_250)
		#expect(try roundTrip(report.encode, DisplayReportMessage.decode) == report)
	}

	@Test func helloRoundTrips() throws {
		let hello = HelloMessage(width: 3456, height: 2234)
		#expect(try roundTrip(hello.encode, HelloMessage.decode) == hello)
	}

	@Test func helloRejectsOtherVersions() {
		var hello = HelloMessage(width: 1, height: 1)
		hello.version = Wire.version + 1
		#expect(throws: WireError.self) { try roundTrip(hello.encode, HelloMessage.decode) }
	}

	@Test func frameBeginRoundTrips() throws {
		let begin = FrameBeginMessage(frameID: .max - 3, captureTime: 123_456_789_012, rectCount: 17)
		#expect(try roundTrip(begin.encode, FrameBeginMessage.decode) == begin)
	}

	@Test func rectRoundTrips() throws {
		let rect = RectMessage(x: 10, y: 20, width: 30, height: 40, byteCount: 30 * 40 * 4)
		#expect(try roundTrip(rect.encode, RectMessage.decode) == rect)
	}

	@Test func presentedRoundTrips() throws {
		let presented = PresentedMessage(frameID: 99)
		#expect(try roundTrip(presented.encode, PresentedMessage.decode) == presented)
	}

	@Test func decodingTheWrongTypeThrows() {
		#expect(throws: WireError.self) {
			try roundTrip(PresentedMessage(frameID: 1).encode, FrameBeginMessage.decode)
		}
	}

	@Test func encodingIsLittleEndian() {
		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Wire.headerSize, alignment: 8)
		defer { buffer.deallocate() }
		HelloMessage(width: 3456, height: 2234).encode(into: buffer)
		let bytes = UnsafeRawBufferPointer(start: buffer, count: Wire.headerSize)
		#expect(Array(bytes[4..<8]) == Array("MKSC".utf8))
		#expect(Array(bytes[12..<16]) == [0x80, 0x0D, 0, 0])
	}

	@Test func rectValidation() throws {
		try RectMessage(x: 0, y: 0, width: 10, height: 10, byteCount: 400).validate(displayWidth: 10, displayHeight: 10)
		#expect(throws: WireError.self) {
			try RectMessage(x: 5, y: 0, width: 6, height: 1, byteCount: 24).validate(displayWidth: 10, displayHeight: 10)
		}
		#expect(throws: WireError.self) {
			try RectMessage(x: 0, y: 0, width: 2, height: 2, byteCount: 15).validate(displayWidth: 10, displayHeight: 10)
		}
		#expect(throws: WireError.self) {
			try RectMessage(x: 0, y: 0, width: 0, height: 2, byteCount: 0).validate(displayWidth: 10, displayHeight: 10)
		}
		#expect(throws: WireError.self) {
			try RectMessage(x: .max, y: 0, width: 2, height: 2, byteCount: 16).validate(displayWidth: 10, displayHeight: 10)
		}
	}

	@Test func viewportFitsOneToOneAndBottomAligns() {
		let same = FrameRenderer.fit(width: 3456, height: 2234, into: 3456, 2234)
		#expect(same.isOneToOne)
		#expect(same.viewport.originX == 0 && same.viewport.originY == 0 && same.viewport.width == 3456)

		let belowNotch = FrameRenderer.fit(width: 3456, height: 2160, into: 3456, 2234)
		#expect(belowNotch.isOneToOne)
		#expect(belowNotch.viewport.originY == 74 && belowNotch.viewport.height == 2160)

		let scaled = FrameRenderer.fit(width: 3456, height: 2234, into: 1728, 1117)
		#expect(!scaled.isOneToOne)
		#expect(scaled.viewport.width == 1728 && scaled.viewport.height == 1117)
	}
}
