// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import QuartzCore
import Testing
@testable import MokaScreen

@Suite struct PresentationDriverTests {
	/// A paused display Mac must keep freeing slots, or the reader blocks and the sender stalls.
	@Test func pausedDriverKeepsTakingFrames() throws {
		let size = 64
		let renderer = try FrameRenderer(stats: ReceiverStats())
		try renderer.configure(width: size, height: size)
		let layer = CAMetalLayer()
		layer.device = renderer.device
		layer.pixelFormat = .bgra8Unorm
		layer.drawableSize = CGSize(width: size, height: size)
		let driver = PresentationDriver(layer: layer, renderer: renderer)
		driver.setPaused(true)
		driver.start()
		defer { driver.stop() }

		let frameCount = FrameRenderer.slotCount * 10
		let done = DispatchSemaphore(value: 0)
		let delivered = Delivered()
		let reader = Thread {
			for id in 1...frameCount {
				guard let slot = renderer.acquireSlot() else { break }
				let rect = ReceivedRect(x: 0, y: 0, width: size, height: size, offset: 0)
				renderer.commit(ReceivedFrame(frameID: UInt64(id), rects: [rect], slot: slot, receivedTime: HostClock.now))
				delivered.count = id
			}
			done.signal()
		}
		reader.start()

		let finished = done.wait(timeout: .now() + 5) == .success
		if !finished {
			renderer.shutDown()
			done.wait()
		}
		#expect(finished)
		#expect(delivered.count == frameCount)
	}
}

@Suite struct InFlightDrawablesTests {
	@Test func aReportFreesItsDrawable() {
		var drawables = InFlightDrawables()
		drawables.add(token: 1, deadline: 100)
		drawables.add(token: 2, deadline: 200)
		let first = drawables.complete(token: 1)
		let again = drawables.complete(token: 1)
		#expect(first)
		#expect(!again)
		#expect(drawables.count == 1)
	}

	@Test func aDrawableThatNeverReportsStopsCountingAtItsDeadline() {
		var drawables = InFlightDrawables()
		drawables.add(token: 1, deadline: 1_000)
		drawables.add(token: 2, deadline: 5_000)
		drawables.setDeadline(3_000, for: 2)
		#expect(drawables.earliestDeadline == 1_000)
		let early = drawables.expire(now: 999)
		let due = drawables.expire(now: 1_000)
		#expect(early == 0)
		#expect(due == 1)
		#expect(drawables.count == 1)
		#expect(drawables.earliestDeadline == 3_000)
		// A late report for an expired drawable changes nothing.
		let late = drawables.complete(token: 1)
		#expect(!late)
		let last = drawables.expire(now: 3_000)
		#expect(last == 1)
		#expect(drawables.earliestDeadline == nil)
	}
}

@Suite struct DisplayTicksTests {
	private let interval: UInt64 = 8_333_333

	@Test func movesATimeToTheNextRefresh() {
		let ticks = DisplayTicks()
		ticks.record(timestamp: 10, duration: 1.0 / 120)
		let last: UInt64 = 10_000_000_000
		let now = last + 2_000_000
		// Between refreshes: the next one.
		#expect(ticks.tick(atOrAfter: last + 3 * interval + 4_000_000, now: now) == last + 4 * interval)
		// On a refresh: that one.
		#expect(ticks.tick(atOrAfter: last + 2 * interval, now: now) == last + 2 * interval)
		// Already past: the last refresh, so the frame is presented at once.
		#expect(ticks.tick(atOrAfter: last - 5_000_000, now: now) == last)
	}

	@Test func knowsNothingWithoutRecentRefreshes() {
		let ticks = DisplayTicks()
		#expect(ticks.tick(atOrAfter: 1_000, now: 2_000) == nil)
		ticks.record(timestamp: 10, duration: 1.0 / 120)
		#expect(ticks.tick(atOrAfter: 12_000_000_000, now: 11_500_000_000) == nil)
	}
}

private final class Delivered: @unchecked Sendable {
	var count = 0
}
