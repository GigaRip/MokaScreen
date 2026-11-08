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

struct StatsTests {
	@Test func recentLatencyIsTheMedianAndHoldsWhileIdle() {
		let stats = SenderStats()
		for ms in [8.0, 9.0, 30.0] {
			stats.recordPresented(latency: ms / 1000)
		}
		#expect(stats.drain().recentLatency == 9)
		// A second with no frames clears the per-second figures but keeps the recent one.
		let idle = stats.drain()
		#expect(idle.latencyP50 == 0)
		#expect(idle.recentLatency == 9)
	}

	@Test func recentLatencyKeepsOnlyTheNewestFrames() {
		let stats = SenderStats()
		for _ in 0..<SenderStats.recentCapacity {
			stats.recordPresented(latency: 0.030)
		}
		for _ in 0..<(SenderStats.recentCapacity / 2 + 1) {
			stats.recordPresented(latency: 0.008)
		}
		#expect(stats.drain().recentLatency == 8)
	}

	@Test func receiverRecentDelayMatchesTheSenderRules() {
		let stats = ReceiverStats()
		for ms in [5.0, 6.0, 40.0] {
			stats.recordPresented(delay: ms / 1000)
		}
		let busy = stats.drain()
		#expect(busy.recentDelay == 6)
		#expect(busy.recentDelayP99 == 40)
		#expect(stats.drain().recentDelay == 6)
		stats.resetRecent()
		#expect(stats.drain().recentDelay == 0)
	}

	@Test func displayReportIsHeldUntilTheNextOneOrAReset() {
		let stats = SenderStats()
		stats.recordDisplayReport(DisplayReportMessage(delayP50Micros: 15_500, delayP99Micros: 19_000, receivedFrames: 60, presentedFrames: 60, intervalMillis: 500))
		let first = stats.drain()
		#expect(first.displayDelay == 15.5)
		#expect(first.displayDelayP99 == 19)
		#expect(first.displayPresentedFPS == 120)
		#expect(stats.drain().displayDelay == 15.5)
		stats.resetRecent()
		#expect(stats.drain().displayDelay == 0)
	}

	@Test func drawsCountDrawablesAndWaitsCountFrames() {
		let stats = ReceiverStats()
		let now: UInt64 = 1_000_000_000
		// Two frames folded into one draw, then one frame drawn on its own.
		stats.recordDraw(receivedTimes: [now - 9_000_000, now - 1_000_000], at: now)
		stats.recordDraw(receivedTimes: [now - 2_000_000], at: now)
		let snapshot = stats.drain()
		#expect(snapshot.draws == 2)
		#expect(snapshot.recentWait == 2)
		#expect(DisplayReportMessage(snapshot).draws == 2)
		#expect(DisplayReportMessage(snapshot).waitP50Micros == 2_000)
	}

	@Test func displayReportCarriesDrawsAndWait() {
		let stats = SenderStats()
		stats.recordDisplayReport(DisplayReportMessage(delayP50Micros: 7_000, delayP99Micros: 9_000, receivedFrames: 120, presentedFrames: 120, intervalMillis: 1000, draws: 60, waitP50Micros: 6_500))
		let snapshot = stats.drain()
		#expect(snapshot.displayDrawsPerSecond == 60)
		#expect(snapshot.displayWait == 6.5)
	}

	@Test func resetForgetsRecentLatency() {
		let stats = SenderStats()
		stats.recordPresented(latency: 0.030)
		stats.resetRecent()
		#expect(stats.drain().recentLatency == 0)
	}
}
