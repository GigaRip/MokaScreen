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

	@Test func resetForgetsRecentLatency() {
		let stats = SenderStats()
		stats.recordPresented(latency: 0.030)
		stats.resetRecent()
		#expect(stats.drain().recentLatency == 0)
	}
}
