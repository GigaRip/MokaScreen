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

	var capturedFPS: Double { interval > 0 ? Double(capturedFrames) / interval : 0 }
	var sentFPS: Double { interval > 0 ? Double(sentFrames) / interval : 0 }
	var gigabitsPerSecond: Double { interval > 0 ? Double(bytes) * 8 / interval / 1e9 : 0 }

	static let csvHeader = "time,captured_fps,sent_fps,superseded,full_frames,gbps,rects_per_frame,mean_coverage_pct,max_coverage_pct,latency_p50_ms,latency_p99_ms,latency_max_ms"

	func csvRow(at date: Date) -> String {
		let rectsPerFrame = sentFrames > 0 ? Double(rects) / Double(sentFrames) : 0
		return [
			ISO8601DateFormatter().string(from: date),
			String(format: "%.1f", capturedFPS), String(format: "%.1f", sentFPS),
			String(supersededFrames), String(fullFrames),
			String(format: "%.3f", gigabitsPerSecond), String(format: "%.1f", rectsPerFrame),
			String(format: "%.2f", meanCoverage * 100), String(format: "%.2f", maxCoverage * 100),
			String(format: "%.2f", latencyP50), String(format: "%.2f", latencyP99), String(format: "%.2f", latencyMax),
		].joined(separator: ",")
	}
}

/// Thread-safe counters for the sender's hot path, drained once per second by the UI.
final class SenderStats: @unchecked Sendable {
	private let lock = NSLock()
	private var current = SenderSnapshot()
	private var coverageSum = 0.0
	private var latencies: [Double] = []
	private var since = Date()

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
		lock.withLock { latencies.append(latency * 1000) }
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
	var bytes = 0
	/// Last byte received → frame handed to the display, in milliseconds.
	var presentDelayP50 = 0.0
	var presentDelayP99 = 0.0

	var receivedFPS: Double { interval > 0 ? Double(receivedFrames) / interval : 0 }
	var presentedFPS: Double { interval > 0 ? Double(presentedFrames) / interval : 0 }
	var gigabitsPerSecond: Double { interval > 0 ? Double(bytes) * 8 / interval / 1e9 : 0 }
}

/// Thread-safe counters for the receiver's hot path.
final class ReceiverStats: @unchecked Sendable {
	private let lock = NSLock()
	private var current = ReceiverSnapshot()
	private var delays: [Double] = []
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
			current = ReceiverSnapshot()
			delays.removeAll(keepingCapacity: true)
			since = now
			return snapshot
		}
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
