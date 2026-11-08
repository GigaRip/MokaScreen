// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// One second of sender activity.
struct SenderSnapshot: Equatable {
	var interval: Double = 0
	var capturedFrames = 0
	var sentFrames = 0
	var supersededFrames = 0
	var fullFrames = 0
	var bytes = 0
	var rects = 0
	/// Mean and max fraction of the display sent per frame, 0...1.
	var meanCoverage = 0.0
	var maxCoverage = 0.0
	/// Capture → `presented` acknowledgement, in milliseconds.
	var latencyP50 = 0.0
	var latencyP99 = 0.0
	var latencyMax = 0.0
	/// Median capture → `presented` acknowledgement over the most recent frames, in
	/// milliseconds; 0 before the first. Unlike the per-second figures it holds its value while
	/// the screen is idle, when only an occasional frame is sent.
	var recentLatency = 0.0
	/// 99th percentile over the same frames as ``recentLatency``.
	var recentLatencyP99 = 0.0
	/// The display Mac's share of ``recentLatency``, from its last report: the rolling median and
	/// p99 from a frame's last byte arriving to it being on glass, in milliseconds; 0 before the
	/// first report.
	var displayDelay = 0.0
	var displayDelayP99 = 0.0
	/// Frames the display Mac put on screen per second, from its last report.
	var displayPresentedFPS = 0.0
	/// Drawables the display Mac presented per second, from its last report. Fewer draws than
	/// frames means frames waited and were folded together.
	var displayDrawsPerSecond = 0.0
	/// The display Mac's rolling median from a frame's last byte arriving to its draw starting,
	/// in milliseconds, from its last report.
	var displayWait = 0.0
	/// Uneven and compared frames per second on the display Mac, from its last pace report.
	var displayUnevenPerSecond = 0.0
	var displayComparedPerSecond = 0.0
	/// Smooth Motion's delay on the display Mac in milliseconds; zero while it is off.
	var displayPacing = 0.0

	var capturedFPS: Double { interval > 0 ? Double(capturedFrames) / interval : 0 }
	var sentFPS: Double { interval > 0 ? Double(sentFrames) / interval : 0 }
	var gigabitsPerSecond: Double { interval > 0 ? Double(bytes) * 8 / interval / 1e9 : 0 }

	static let csvHeader = "time,captured_fps,sent_fps,superseded,full_frames,gbps,rects_per_frame,mean_coverage_pct,max_coverage_pct,latency_p50_ms,latency_p99_ms,latency_max_ms,recent_latency_p50_ms,display_share_p50_ms,display_share_p99_ms,display_presented_fps,display_draws_per_s,display_wait_p50_ms,display_uneven_per_s,display_compared_per_s,display_pacing_ms"

	func csvRow(at date: Date) -> String {
		let rectsPerFrame = sentFrames > 0 ? Double(rects) / Double(sentFrames) : 0
		return [
			ISO8601DateFormatter().string(from: date),
			String(format: "%.1f", capturedFPS), String(format: "%.1f", sentFPS),
			String(supersededFrames), String(fullFrames),
			String(format: "%.3f", gigabitsPerSecond), String(format: "%.1f", rectsPerFrame),
			String(format: "%.2f", meanCoverage * 100), String(format: "%.2f", maxCoverage * 100),
			String(format: "%.2f", latencyP50), String(format: "%.2f", latencyP99), String(format: "%.2f", latencyMax),
			String(format: "%.2f", recentLatency),
			String(format: "%.2f", displayDelay), String(format: "%.2f", displayDelayP99), String(format: "%.1f", displayPresentedFPS),
			String(format: "%.1f", displayDrawsPerSecond), String(format: "%.2f", displayWait),
			String(format: "%.1f", displayUnevenPerSecond), String(format: "%.1f", displayComparedPerSecond), String(format: "%.2f", displayPacing),
		].joined(separator: ",")
	}
}

/// Thread-safe counters for the sender's hot path, drained once per second by the UI.
final class SenderStats: @unchecked Sendable {
	private let lock = NSLock()
	private var current = SenderSnapshot()
	private var coverageSum = 0.0
	private var latencies: [Double] = []
	private var recent = RecentLatencies()
	private var displayReport: DisplayReportMessage?
	private var paceReport: PaceReportMessage?
	private var since = Date()

	/// Frames behind ``SenderSnapshot/recentLatency``.
	static let recentCapacity = RecentLatencies.capacity

	func recordCaptured() {
		lock.withLock { current.capturedFrames += 1 }
	}

	func recordSuperseded() {
		lock.withLock { current.supersededFrames += 1 }
	}

	func recordSent(bytes: Int, rects: Int, coverage: Double) {
		lock.withLock {
			current.sentFrames += 1
			current.bytes += bytes
			current.rects += rects
			coverageSum += coverage
			current.maxCoverage = max(current.maxCoverage, coverage)
			if coverage >= 0.999 { current.fullFrames += 1 }
		}
	}

	/// - Parameter latency: Seconds from capture to the receiver's acknowledgement.
	func recordPresented(latency: Double) {
		lock.withLock {
			let milliseconds = latency * 1000
			latencies.append(milliseconds)
			recent.append(milliseconds)
		}
	}

	/// Keeps the display Mac's latest report for the next snapshot. Its delays are already rolling
	/// figures, so the report is held until the next one arrives.
	func recordDisplayReport(_ report: DisplayReportMessage) {
		lock.withLock { displayReport = report }
	}

	/// Keeps the display Mac's latest pace report for the next snapshot.
	func recordPaceReport(_ report: PaceReportMessage) {
		lock.withLock { paceReport = report }
	}

	/// Forgets the recent latencies and the display Mac's report, so a new connection is not
	/// judged by the previous one.
	func resetRecent() {
		lock.withLock {
			recent.removeAll()
			displayReport = nil
			paceReport = nil
		}
	}

	/// Returns the activity since the previous call and starts a new interval.
	func drain() -> SenderSnapshot {
		lock.withLock {
			var snapshot = current
			let now = Date()
			snapshot.interval = now.timeIntervalSince(since)
			snapshot.meanCoverage = current.sentFrames > 0 ? coverageSum / Double(current.sentFrames) : 0
			let sorted = latencies.sorted()
			snapshot.latencyP50 = Percentile.of(sorted, 0.5)
			snapshot.latencyP99 = Percentile.of(sorted, 0.99)
			snapshot.latencyMax = sorted.last ?? 0
			(snapshot.recentLatency, snapshot.recentLatencyP99) = recent.percentiles()
			if let report = displayReport {
				snapshot.displayDelay = Double(report.delayP50Micros) / 1000
				snapshot.displayDelayP99 = Double(report.delayP99Micros) / 1000
				snapshot.displayPresentedFPS = report.intervalMillis > 0 ? Double(report.presentedFrames) * 1000 / Double(report.intervalMillis) : 0
				snapshot.displayDrawsPerSecond = report.intervalMillis > 0 ? Double(report.draws) * 1000 / Double(report.intervalMillis) : 0
				snapshot.displayWait = Double(report.waitP50Micros) / 1000
			}
			if let report = paceReport, report.intervalMillis > 0 {
				let seconds = Double(report.intervalMillis) / 1000
				snapshot.displayUnevenPerSecond = Double(report.unevenFrames) / seconds
				snapshot.displayComparedPerSecond = Double(report.comparedFrames) / seconds
				snapshot.displayPacing = Double(report.pacingMicros) / 1000
			}
			current = SenderSnapshot()
			coverageSum = 0
			latencies.removeAll(keepingCapacity: true)
			since = now
			return snapshot
		}
	}
}

/// One second of receiver activity.
struct ReceiverSnapshot: Equatable {
	var interval: Double = 0
	var receivedFrames = 0
	var presentedFrames = 0
	/// Drawables presented; several frames that arrived together share one.
	var draws = 0
	var bytes = 0
	/// Median over the most recent frames from the last byte arriving to the draw starting, in
	/// milliseconds, held while the screen is idle.
	var recentWait = 0.0
	/// Consecutive frames whose spacing on the glass differed from their spacing at capture by
	/// more than half a refresh, out of ``comparedFrames``.
	var unevenFrames = 0
	/// Consecutive frames captured less than three refreshes apart, so compared for evenness.
	var comparedFrames = 0
	/// Smooth Motion's current delay in milliseconds; zero while it is off.
	var pacing = 0.0
	/// Last byte received → frame handed to the display, in milliseconds.
	var presentDelayP50 = 0.0
	var presentDelayP99 = 0.0
	/// Median and 99th percentile over the most recent frames, held while the screen is idle.
	var recentDelay = 0.0
	var recentDelayP99 = 0.0

	var receivedFPS: Double { interval > 0 ? Double(receivedFrames) / interval : 0 }
	var presentedFPS: Double { interval > 0 ? Double(presentedFrames) / interval : 0 }
	var gigabitsPerSecond: Double { interval > 0 ? Double(bytes) * 8 / interval / 1e9 : 0 }
}

/// Thread-safe counters for the receiver's hot path.
final class ReceiverStats: @unchecked Sendable {
	private let lock = NSLock()
	private var current = ReceiverSnapshot()
	private var delays: [Double] = []
	private var recent = RecentLatencies()
	private var recentWaits = RecentLatencies()
	private var pacing = 0.0
	/// Capture and glass time of the last frame put on glass, for judging the next one's spacing.
	private var lastGlass: (capture: UInt64, glass: UInt64)?
	private var since = Date()

	func recordReceived(bytes: Int) {
		lock.withLock {
			current.receivedFrames += 1
			current.bytes += bytes
		}
	}

	/// - Parameter delay: Seconds from the frame's last byte arriving to its presentation being scheduled.
	func recordPresented(delay: Double) {
		lock.withLock {
			current.presentedFrames += 1
			delays.append(delay * 1000)
			recent.append(delay * 1000)
		}
	}

	/// Records one drawable and how long each frame in it waited to be drawn.
	/// - Parameters:
	///   - receivedTimes: Host times, in nanoseconds, at which each frame's last byte arrived.
	///   - now: The host time the draw started.
	func recordDraw(receivedTimes: [UInt64], at now: UInt64) {
		lock.withLock {
			current.draws += 1
			for received in receivedTimes {
				recentWaits.append(Double(now &- received) / 1e6)
			}
		}
	}

	/// Records Smooth Motion's current delay; zero while it is off.
	func recordPacing(milliseconds: Double) {
		lock.withLock { pacing = milliseconds }
	}

	/// Compares a frame's spacing on the glass with its spacing at capture, against the one
	/// before it. All times in nanoseconds; capture times are on the sender's clock.
	func recordGlass(captureTime: UInt64, glassTime: UInt64, refreshNanos: UInt64) {
		lock.withLock {
			defer { lastGlass = (captureTime, glassTime) }
			guard let last = lastGlass, captureTime > last.capture, glassTime >= last.glass else { return }
			let captured = Int64(captureTime - last.capture)
			guard captured < Int64(refreshNanos * 3) else { return }
			current.comparedFrames += 1
			let shown = Int64(glassTime - last.glass)
			if abs(shown - captured) > Int64(refreshNanos / 2) {
				current.unevenFrames += 1
			}
		}
	}

	/// Forgets the recent delays, so a new connection is not judged by the previous one.
	func resetRecent() {
		lock.withLock {
			recent.removeAll()
			recentWaits.removeAll()
			lastGlass = nil
		}
	}

	func drain() -> ReceiverSnapshot {
		lock.withLock {
			var snapshot = current
			let now = Date()
			snapshot.interval = now.timeIntervalSince(since)
			let sorted = delays.sorted()
			snapshot.presentDelayP50 = Percentile.of(sorted, 0.5)
			snapshot.presentDelayP99 = Percentile.of(sorted, 0.99)
			(snapshot.recentDelay, snapshot.recentDelayP99) = recent.percentiles()
			snapshot.recentWait = recentWaits.percentiles().p50
			snapshot.pacing = pacing
			current = ReceiverSnapshot()
			delays.removeAll(keepingCapacity: true)
			since = now
			return snapshot
		}
	}
}

/// The most recent latencies, in milliseconds, oldest overwritten first.
///
/// Their median is the headline latency: two seconds of frames at 120 Hz is enough that the
/// occasional slow full-screen frame sent while the screen is idle does not swing it.
struct RecentLatencies {
	static let capacity = 240
	private var values: [Double] = []
	private var next = 0

	mutating func append(_ milliseconds: Double) {
		if values.count < Self.capacity {
			values.append(milliseconds)
		} else {
			values[next] = milliseconds
		}
		next = (next + 1) % Self.capacity
	}

	mutating func removeAll() {
		values.removeAll(keepingCapacity: true)
		next = 0
	}

	/// Median and 99th percentile; zeros when empty.
	func percentiles() -> (p50: Double, p99: Double) {
		let sorted = values.sorted()
		return (Percentile.of(sorted, 0.5), Percentile.of(sorted, 0.99))
	}
}

enum Percentile {
	/// Nearest-rank percentile of an ascending array; 0 when empty.
	static func of(_ sorted: [Double], _ p: Double) -> Double {
		guard !sorted.isEmpty else { return 0 }
		let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
		return sorted[min(max(rank, 0), sorted.count - 1)]
	}
}

/// Appends one CSV row per second of sender activity to `~/Library/Logs/MokaScreen/`, for
/// studying dirty-rectangle sizes during real work (design spike 3).
final class StatsRecorder {
	let url: URL
	private let handle: FileHandle

	init() throws {
		let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MokaScreen")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
		url = directory.appending(path: "sender-\(formatter.string(from: Date())).csv")
		FileManager.default.createFile(atPath: url.path, contents: Data((SenderSnapshot.csvHeader + "\n").utf8))
		handle = try FileHandle(forWritingTo: url)
		handle.seekToEndOfFile()
	}

	func append(_ snapshot: SenderSnapshot) {
		handle.write(Data((snapshot.csvRow(at: Date()) + "\n").utf8))
	}

	deinit {
		try? handle.close()
	}
}
