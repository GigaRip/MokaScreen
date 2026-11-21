// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import os
import Synchronization

/// Works out how far the extending Mac's host clock is from this Mac's, from timestamped
/// pings.
///
/// The display Mac notes its time `t1` and sends a ping; the extending Mac notes its time `t2`
/// on receipt and `t3` when it replies; the reply arrives at `t4`. The round trip on the cable is
/// `(t4 − t1) − (t3 − t2)`, and if both directions took equally long the clocks differ by
/// `((t1 − t2) + (t4 − t3)) / 2`. The directions are not always equal: a reply queued behind a
/// frame's pixels waits for them, so its round trip is long. The estimate is therefore taken
/// from the exchange with the shortest round trip among the recent ones, and it is wrong by at
/// most half that round trip.
struct ClockOffsetEstimator {
	/// Exchanges remembered: four seconds at ``ClockSync/pingInterval``. Host clocks drift apart
	/// by tens of microseconds a second at most, so the oldest is still good to well under a
	/// tenth of a refresh.
	static let window = 16
	/// Exchanges slower than this are not used. During a long scroll every reply can sit behind
	/// a full-screen frame; the last good estimate then stands until a quick exchange gets
	/// through.
	static let maximumRoundTripNanos: Int64 = 1_000_000

	private var samples: [(offset: Int64, roundTrip: Int64)] = []
	private var next = 0
	/// This Mac's host time minus the extending Mac's, in nanoseconds, and the round trip of the
	/// exchange it came from; nil until an exchange has been quick enough.
	private(set) var estimate: (offset: Int64, roundTrip: Int64)?

	init() {
		samples.reserveCapacity(Self.window)
	}

	/// Records one exchange. All times are host nanoseconds: `sent` and `received` on this Mac's
	/// clock, `peerReceived` and `peerSent` on the extending Mac's.
	mutating func record(sent: UInt64, peerReceived: UInt64, peerSent: UInt64, received: UInt64) {
		let roundTrip = Int64(bitPattern: received &- sent) - Int64(bitPattern: peerSent &- peerReceived)
		guard roundTrip >= 0 else { return }
		let offset = (Int64(bitPattern: sent &- peerReceived) + Int64(bitPattern: received &- peerSent)) / 2
		if samples.count < Self.window {
			samples.append((offset, roundTrip))
		} else {
			samples[next] = (offset, roundTrip)
		}
		next = (next + 1) % Self.window
		if let best = samples.min(by: { $0.roundTrip < $1.roundTrip }), best.roundTrip <= Self.maximumRoundTripNanos {
			estimate = best
		}
	}
}

/// The clock offset for one connection: fed by the reader thread as replies arrive, read by the
/// render thread for every frame.
final class ClockSync: Sendable {
	/// How often the display Mac pings.
	static let pingInterval: DispatchTimeInterval = .milliseconds(250)

	private static let unknown = Int64.min
	private let estimator = Mutex(ClockOffsetEstimator())
	private let currentOffset = Atomic<Int64>(ClockSync.unknown)
	private let currentRoundTrip = Atomic<Int64>(0)

	/// This Mac's host time minus the extending Mac's, in nanoseconds; nil until known.
	var offset: Int64? {
		let value = currentOffset.load(ordering: .relaxed)
		return value == Self.unknown ? nil : value
	}

	/// The round trip of the exchange behind ``offset``, in microseconds; 0 until known.
	var roundTripMicros: Int {
		Int(currentRoundTrip.load(ordering: .relaxed) / 1000)
	}

	/// Records the reply to a ping. Times as in ``ClockOffsetEstimator/record(sent:peerReceived:peerSent:received:)``.
	func record(sent: UInt64, peerReceived: UInt64, peerSent: UInt64, received: UInt64) {
		let (estimate, wasKnown) = estimator.withLock { estimator in
			let wasKnown = estimator.estimate != nil
			estimator.record(sent: sent, peerReceived: peerReceived, peerSent: peerSent, received: received)
			return (estimator.estimate, wasKnown)
		}
		guard let estimate else { return }
		currentRoundTrip.store(estimate.roundTrip, ordering: .relaxed)
		currentOffset.store(estimate.offset, ordering: .relaxed)
		if !wasKnown {
			Log.transport.notice("Clocks synchronized: round trip \(estimate.roundTrip / 1000, privacy: .public) µs")
		}
	}
}
