// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// Chooses when a frame should reach the glass under Smooth Motion.
///
/// The extending Mac's virtual display and this Mac's panel are separate 120 Hz clocks, and each
/// frame's trip varies with capture delivery and with how many pixels changed. Drawn on arrival,
/// frames captured a refresh apart can land two refreshes apart or on the same refresh, which
/// reads as judder while scrolling.
///
/// The Macs' clocks are unrelated, so the pacer works with each frame's transit: its arrival on
/// this Mac's clock minus its capture on the sender's. The smallest transit over the recent
/// frames stands for the clock offset plus the quickest trip, and a frame's lateness is its
/// transit beyond that. Each frame is scheduled for its capture time plus the smallest transit
/// plus ``delay``, which covers the 99th-percentile lateness of the last second, so frames reach
/// the glass spaced as they were captured. Used only on the render thread.
struct FramePacer {
	/// Frames whose transit is remembered: two seconds at 120 Hz. The quickest trip is taken over
	/// all of them.
	static let window = 240
	/// Lateness is judged over the frames received in the last second only, so the delay follows
	/// what the picture is doing now rather than a scroll that has ended.
	static let latenessHorizonNanos: UInt64 = 1_000_000_000
	/// Frames between recomputing ``delay``, so the schedule's phase holds steady between updates.
	static let updateInterval = 30
	/// Also recompute after this long, so a stretch with few frames, such as typing, still lets the
	/// delay fall.
	static let updateAfterNanos: UInt64 = 250_000_000
	/// A gap between frames this long starts the schedule afresh: the delay is set outright from the
	/// frames that follow instead of easing down from what the last burst needed.
	static let restartAfterNanos: UInt64 = 500_000_000
	/// Added to the 99th-percentile lateness, for the draw and the hand-off to macOS.
	static let guardNanos: Int64 = 500_000
	static let minimumDelayNanos: Int64 = 500_000
	/// A scroll changes most of the screen in every frame, about 26 MB, and the trip of such frames
	/// varied by up to 15 ms with the cable's throughput in a frame timing recording on
	/// 2026-11-14; capped at one refresh, a third of them reached the glass a refresh early or
	/// late. 30 ms leaves room above the largest Develop › Smooth Motion Minimum Delay choice.
	static let maximumDelayNanos: Int64 = 30_000_000

	private var received: [UInt64] = []
	private var transits: [Int64] = []
	private var next = 0
	private var sinceUpdate = 0
	private var lastUpdate: UInt64 = 0
	private var lastReceived: UInt64 = 0
	/// False until the first update after a start or a long gap, which sets ``delay`` outright
	/// instead of easing toward it.
	private var settled = false
	private var scratch: [Int64] = []
	private(set) var minimumTransit: Int64 = .max
	/// Nanoseconds added beyond the quickest trip, following how late recent frames were.
	private(set) var delay: Int64 = maximumDelayNanos
	/// The least delay to schedule with, whatever recent frames needed (Develop › Smooth Motion
	/// Minimum Delay). Zero leaves the delay adaptive.
	var floorNanos: Int64 = 0

	/// The delay frames are scheduled with: ``delay``, raised to ``floorNanos``.
	var effectiveDelay: Int64 {
		max(delay, min(floorNanos, Self.maximumDelayNanos))
	}

	init() {
		received.reserveCapacity(Self.window)
		transits.reserveCapacity(Self.window)
		scratch.reserveCapacity(Self.window)
	}

	/// Records a frame's trip.
	/// - Parameters:
	///   - captureTime: Sender host time of capture, in nanoseconds.
	///   - receivedTime: This Mac's host time when its last byte arrived, in nanoseconds.
	mutating func record(captureTime: UInt64, receivedTime: UInt64) {
		let transit = Int64(bitPattern: receivedTime &- captureTime)
		if lastReceived != 0, receivedTime &- lastReceived > Self.restartAfterNanos {
			settled = false
			sinceUpdate = Self.updateInterval
		}
		lastReceived = receivedTime
		if transits.count < Self.window {
			received.append(receivedTime)
			transits.append(transit)
		} else {
			received[next] = receivedTime
			transits[next] = transit
			next = (next + 1) % Self.window
		}
		minimumTransit = min(minimumTransit, transit)
		sinceUpdate += 1
		if sinceUpdate >= Self.updateInterval || receivedTime &- lastUpdate >= Self.updateAfterNanos {
			update(now: receivedTime)
		}
	}

	/// This Mac's host time, in nanoseconds, at which a frame captured at `captureTime` should
	/// reach the glass; nil before any frame has been recorded.
	func glassTime(captureTime: UInt64) -> UInt64? {
		guard minimumTransit != .max else { return nil }
		return captureTime &+ UInt64(bitPattern: minimumTransit &+ effectiveDelay)
	}

	/// Forgets the recorded trips, e.g. when the sender's clock may have changed.
	mutating func reset() {
		self = FramePacer()
	}

	private mutating func update(now: UInt64) {
		sinceUpdate = 0
		lastUpdate = now
		guard let fastest = transits.min() else { return }
		// The window's minimum, not the all-time one, so the clocks' slow drift is followed.
		minimumTransit = fastest
		scratch.removeAll(keepingCapacity: true)
		for (time, transit) in zip(received, transits) where now &- time <= Self.latenessHorizonNanos {
			scratch.append(transit)
		}
		guard !scratch.isEmpty else { return }
		scratch.sort()
		let p99 = scratch[min(scratch.count - 1, Int((Double(scratch.count) * 0.99).rounded(.up)) - 1)]
		let wanted = min(Self.maximumDelayNanos, max(Self.minimumDelayNanos, p99 - fastest + Self.guardNanos))
		// Rise at once so late frames stop missing their refresh; fall to a quarter of the excess
		// per update, under a second from the cap to a quiet picture's delay, in steps small
		// enough that the schedule does not jump by many refreshes at once.
		delay = !settled || wanted > delay ? wanted : wanted + (delay - wanted) / 4
		settled = true
	}
}
