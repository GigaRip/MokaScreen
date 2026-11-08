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
/// plus ``delay``, which covers the 99th-percentile lateness, so frames reach the glass spaced as
/// they were captured. Used only on the render thread.
struct FramePacer {
	/// Frames whose transit is remembered: two seconds at 120 Hz.
	static let window = 240
	/// Frames between recomputing ``delay``, so the schedule's phase holds steady between updates.
	static let updateInterval = 30
	/// Added to the 99th-percentile lateness, for the draw and the hand-off to macOS.
	static let guardNanos: Int64 = 500_000
	static let minimumDelayNanos: Int64 = 500_000
	/// Smooth Motion never delays a frame by more than one refresh at 120 Hz.
	static let maximumDelayNanos: Int64 = 8_333_333
	/// How fast ``delay`` falls when the trip gets steadier, per update.
	static let decayNanos: Int64 = 250_000

	private var transits: [Int64] = []
	private var next = 0
	private var sinceUpdate = 0
	/// False until the first update, which sets ``delay`` outright instead of easing toward it.
	private var settled = false
	private var scratch: [Int64] = []
	private(set) var minimumTransit: Int64 = .max
	/// Nanoseconds added beyond the quickest trip.
	private(set) var delay: Int64 = maximumDelayNanos

	init() {
		transits.reserveCapacity(Self.window)
		scratch.reserveCapacity(Self.window)
	}

	/// Records a frame's trip.
	/// - Parameters:
	///   - captureTime: Sender host time of capture, in nanoseconds.
	///   - receivedTime: This Mac's host time when its last byte arrived, in nanoseconds.
	mutating func record(captureTime: UInt64, receivedTime: UInt64) {
		let transit = Int64(bitPattern: receivedTime &- captureTime)
		if transits.count < Self.window {
			transits.append(transit)
		} else {
			transits[next] = transit
			next = (next + 1) % Self.window
		}
		minimumTransit = min(minimumTransit, transit)
		sinceUpdate += 1
		if sinceUpdate >= Self.updateInterval {
			sinceUpdate = 0
			update()
		}
	}

	/// This Mac's host time, in nanoseconds, at which a frame captured at `captureTime` should
	/// reach the glass; nil before any frame has been recorded.
	func glassTime(captureTime: UInt64) -> UInt64? {
		guard minimumTransit != .max else { return nil }
		return captureTime &+ UInt64(bitPattern: minimumTransit &+ delay)
	}

	/// Forgets the recorded trips, e.g. when the sender's clock may have changed.
	mutating func reset() {
		self = FramePacer()
	}

	private mutating func update() {
		scratch.removeAll(keepingCapacity: true)
		scratch.append(contentsOf: transits)
		scratch.sort()
		guard let fastest = scratch.first else { return }
		// The window's minimum, not the all-time one, so the clocks' slow drift is followed.
		minimumTransit = fastest
		let p99 = scratch[min(scratch.count - 1, Int((Double(scratch.count) * 0.99).rounded(.up)) - 1)]
		let wanted = min(Self.maximumDelayNanos, max(Self.minimumDelayNanos, p99 - fastest + Self.guardNanos))
		// Rise at once so late frames stop missing their refresh; fall slowly so one quiet stretch
		// does not shift the schedule back and forth.
		delay = !settled || wanted > delay ? wanted : max(wanted, delay - Self.decayNanos)
		settled = true
	}
}
