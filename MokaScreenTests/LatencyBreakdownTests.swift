// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI
import Testing
@testable import MokaScreen

struct LatencyBreakdownTests {
	private let refresh = 1000.0 / 120

	@Test func smoothMotionsHoldIsShownApartFromTheDisplayMac() {
		var stats = SenderSnapshot()
		stats.recentLatency = 18.8
		stats.displayDelay = 15.6
		stats.displayWait = 7.0
		stats.displayPacing = 20
		let parts = LatencyBreakdown.parts(of: stats)
		#expect(abs(parts.captureAndCable - 3.2) < 1e-9)
		#expect(abs(parts.smoothMotion - 7.0) < 1e-9)
		#expect(abs(parts.display - 8.6) < 1e-9)
	}

	@Test func withoutSmoothMotionTheWaitStaysWithTheDisplayMac() {
		var stats = SenderSnapshot()
		stats.recentLatency = 9
		stats.displayDelay = 6.5
		stats.displayWait = 0.4
		let parts = LatencyBreakdown.parts(of: stats)
		#expect(parts.smoothMotion == 0)
		#expect(parts.display == 6.5)
	}

	@Test func colourAllowsForSmoothMotionsDelay() {
		// Without Smooth Motion: green to two refreshes, amber to three.
		#expect(LatencyBreakdown.tint(total: 12, smoothMotionDelay: 0, frameBudget: refresh) == .green)
		#expect(LatencyBreakdown.tint(total: 18.8, smoothMotionDelay: 0, frameBudget: refresh) == .orange)
		#expect(LatencyBreakdown.tint(total: 30, smoothMotionDelay: 0, frameBudget: refresh) == .red)
		// With a 20 ms delay, the same trip is on schedule.
		#expect(LatencyBreakdown.tint(total: 18.8, smoothMotionDelay: 20, frameBudget: refresh) == .green)
		#expect(LatencyBreakdown.tint(total: 40, smoothMotionDelay: 20, frameBudget: refresh) == .orange)
		#expect(LatencyBreakdown.tint(total: 50, smoothMotionDelay: 20, frameBudget: refresh) == .red)
	}
}
