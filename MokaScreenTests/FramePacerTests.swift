// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Testing
@testable import MokaScreen

struct FramePacerTests {
	private static let refresh: UInt64 = 8_333_333
	/// An arbitrary offset between the two Macs' clocks.
	private static let clockOffset: UInt64 = 5_000_000_000_000

	@Test func spacesFramesAsTheyWereCapturedDespiteUnevenArrival() throws {
		var pacer = FramePacer()
		// Trips of 2 to 5 ms, repeating.
		let trips: [UInt64] = [2_000_000, 5_000_000, 3_000_000, 4_500_000, 2_500_000]
		var glass: [UInt64] = []
		for n in 0..<240 {
			let capture = UInt64(n) * Self.refresh
			pacer.record(captureTime: capture, receivedTime: capture + Self.clockOffset + trips[n % trips.count])
			if n >= 120 {
				glass.append(try #require(pacer.glassTime(captureTime: capture)))
			}
		}
		// Every frame is scheduled after its own arrival, a refresh after the one before it.
		for (index, time) in glass.enumerated() {
			let capture = UInt64(index + 120) * Self.refresh
			#expect(time >= capture + Self.clockOffset + 5_000_000)
		}
		for pair in zip(glass, glass.dropFirst()) {
			#expect(pair.1 - pair.0 == Self.refresh)
		}
		// The delay covers the 3 ms spread plus the guard, no more than a refresh.
		#expect(pacer.delay == 3_500_000)
	}

	@Test func delayNeverExceedsOneRefresh() {
		var pacer = FramePacer()
		for n in 0..<240 {
			let capture = UInt64(n) * Self.refresh
			let trip: UInt64 = n % 2 == 0 ? 1_000_000 : 30_000_000
			pacer.record(captureTime: capture, receivedTime: capture + Self.clockOffset + trip)
		}
		#expect(pacer.delay == FramePacer.maximumDelayNanos)
	}

	@Test func unevenFramesAreCountedAgainstTheirCaptureSpacing() {
		let stats = ReceiverStats()
		let refresh = Self.refresh
		// Captured a refresh apart; the third lands two refreshes after the second.
		stats.recordGlass(captureTime: 0, glassTime: 100 * refresh, refreshNanos: refresh)
		stats.recordGlass(captureTime: refresh, glassTime: 101 * refresh, refreshNanos: refresh)
		stats.recordGlass(captureTime: 2 * refresh, glassTime: 103 * refresh, refreshNanos: refresh)
		// A pause in the picture is not unevenness.
		stats.recordGlass(captureTime: 60 * refresh, glassTime: 200 * refresh, refreshNanos: refresh)
		let snapshot = stats.drain()
		#expect(snapshot.comparedFrames == 2)
		#expect(snapshot.unevenFrames == 1)
	}
}
