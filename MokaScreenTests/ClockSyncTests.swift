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

struct ClockSyncTests {
	/// The display Mac's clock minus the extending Mac's.
	private static let offset: Int64 = 7_000_000_000_123
	private static let start: UInt64 = 50_000_000_000_000

	/// One exchange starting at `sent` on the display Mac's clock, with the given one-way times
	/// and time spent on the extending Mac, all in nanoseconds.
	private func exchange(_ estimator: inout ClockOffsetEstimator, sent: UInt64, out: Int64, held: Int64 = 20_000, back: Int64) {
		let peerReceived = UInt64(Int64(sent) - Self.offset + out)
		let peerSent = UInt64(Int64(peerReceived) + held)
		let received = UInt64(Int64(peerSent) + Self.offset + back)
		estimator.record(sent: sent, peerReceived: peerReceived, peerSent: peerSent, received: received)
	}

	@Test func equalTripsGiveTheExactOffset() throws {
		var estimator = ClockOffsetEstimator()
		exchange(&estimator, sent: Self.start, out: 60_000, back: 60_000)
		let estimate = try #require(estimator.estimate)
		#expect(estimate.offset == Self.offset)
		// The time the extending Mac held the ping is not part of the round trip.
		#expect(estimate.roundTrip == 120_000)
	}

	@Test func theQuickestRecentExchangeWins() throws {
		var estimator = ClockOffsetEstimator()
		// A reply stuck behind a frame: 600 µs back against 60 µs out.
		exchange(&estimator, sent: Self.start, out: 60_000, back: 600_000)
		#expect(try #require(estimator.estimate).offset == Self.offset + 270_000)
		exchange(&estimator, sent: Self.start + 250_000_000, out: 50_000, back: 70_000)
		let estimate = try #require(estimator.estimate)
		#expect(estimate.offset == Self.offset + 10_000)
		// The error is never more than half the round trip.
		#expect(abs(estimate.offset - Self.offset) <= estimate.roundTrip / 2)
	}

	@Test func slowExchangesAloneGiveNoEstimate() {
		var estimator = ClockOffsetEstimator()
		for n in 0..<4 {
			exchange(&estimator, sent: Self.start + UInt64(n) * 250_000_000, out: 60_000, back: 9_000_000)
		}
		#expect(estimator.estimate == nil)
	}

	@Test func theLastGoodEstimateStandsThroughABusyStretch() throws {
		var estimator = ClockOffsetEstimator()
		exchange(&estimator, sent: Self.start, out: 60_000, back: 60_000)
		// Longer than the window: every reply waits behind a full-screen frame.
		for n in 1...(ClockOffsetEstimator.window * 2) {
			exchange(&estimator, sent: Self.start + UInt64(n) * 250_000_000, out: 60_000, back: 9_000_000)
		}
		#expect(try #require(estimator.estimate).offset == Self.offset)
	}

	@Test func clockSyncPublishesTheEstimate() {
		let clock = ClockSync()
		#expect(clock.offset == nil)
		#expect(clock.roundTripMicros == 0)
		clock.record(sent: 1_000_000, peerReceived: 500_050_000, peerSent: 500_060_000, received: 1_110_000)
		#expect(clock.offset == -499_000_000)
		#expect(clock.roundTripMicros == 100)
	}
}
