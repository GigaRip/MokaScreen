// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import SwiftUI
import Testing
@testable import MokaScreen

/// Renders each role's window to PNG files for checking the layout by eye, without running
/// the app. Runs only when asked: `TEST_RUNNER_MOKASCREEN_SNAPSHOT_DIR=<dir> xcodebuild … test`.
@MainActor
struct WindowSnapshotTests {
	private static let directory = ProcessInfo.processInfo.environment["MOKASCREEN_SNAPSHOT_DIR"]

	@Test(.enabled(if: directory != nil))
	func renderWindows() throws {
		let directory = URL(fileURLWithPath: try #require(Self.directory))
		// A private defaults suite, so the app's real "Show Statistics" setting is untouched.
		let defaults = try #require(UserDefaults(suiteName: "com.gigarip.mokascreen.snapshots"))
		let model = AppModel()
		var connected = SenderSnapshot()
		connected.recentLatency = 8.4
		let senderStates: [(String, SenderSession.Status, Int?, SenderSnapshot)] = [
			("stopped", .stopped, nil, SenderSnapshot()),
			("permission", .needsPermission, nil, SenderSnapshot()),
			("connected", .connected("Brian's MacBook Pro"), 120, connected),
		]
		for showsStatistics in [false, true] {
			defaults.set(showsStatistics, forKey: StatisticsPreference.key)
			let suffix = showsStatistics ? "-statistics" : ""
			for (name, status, refreshRate, stats) in senderStates {
				model.sender.applySnapshotState(status: status, refreshRate: refreshRate, stats: stats)
				try render(SenderView(session: model.sender), model: model, defaults: defaults, to: directory.appending(path: "sender-\(name)\(suffix).png"))
			}
			try render(ReceiverView(session: model.receiver), model: model, defaults: defaults, to: directory.appending(path: "receiver\(suffix).png"))
		}
		model.sender.applySnapshotState(status: .stopped)
	}

	@Test(.enabled(if: directory != nil))
	func renderStatisticsOverlay() throws {
		let directory = URL(fileURLWithPath: try #require(Self.directory))
		for (name, base) in [("green", 5.6), ("amber", 11.0)] {
			var history: [ReceiverSnapshot] = []
			for second in 0..<StatisticsPanelContent.historyLength {
				var snapshot = ReceiverSnapshot()
				snapshot.interval = 1
				snapshot.receivedFrames = 118
				snapshot.presentedFrames = 120
				snapshot.bytes = 310_000_000
				let wobble = sin(Double(second) / 4) * 0.9 + (second == 41 ? 3.5 : 0)
				snapshot.presentDelayP50 = base + wobble
				snapshot.presentDelayP99 = base + 2.8 + abs(wobble) * 1.6
				// Idle for the first 12 seconds, then a rolling figure that drifts slowly.
				snapshot.recentDelay = second < 12 ? 0 : base + wobble * 0.5
				snapshot.recentDelayP99 = second < 12 ? 0 : base + 3.4 + abs(wobble)
				history.append(snapshot)
			}
			try renderPanel(StatisticsPanelContent(receiver: history.last!, history: history, refreshRate: 120, source: "3456 × 2234"), to: directory.appending(path: "overlay-\(name).png"))
		}

		var senderHistory: [SenderSnapshot] = []
		for second in 0..<StatisticsPanelContent.historyLength {
			var snapshot = SenderSnapshot()
			snapshot.interval = 1
			snapshot.capturedFrames = 120
			snapshot.sentFrames = 118
			snapshot.bytes = 300_000_000
			snapshot.meanCoverage = 0.031
			let wobble = sin(Double(second) / 5) * 1.6
			snapshot.latencyP50 = 21.5 + wobble
			snapshot.latencyP99 = 26 + abs(wobble) * 2
			snapshot.recentLatency = 21.5 + wobble * 0.5
			snapshot.recentLatencyP99 = 27.8 + abs(wobble)
			senderHistory.append(snapshot)
		}
		try renderPanel(StatisticsPanelContent(sender: senderHistory.last!, history: senderHistory, refreshRate: 120, display: "3456 × 2234"), to: directory.appending(path: "overlay-sender.png"))
	}

	private func renderPanel(_ content: StatisticsPanelContent, to url: URL) throws {
		do {
			let panel = StatisticsPanel(content: content)
				.padding(40)
				.background {
					// Stands in for the shared screen behind the panel.
					LinearGradient(colors: [.indigo, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
				}
			let host = NSHostingView(rootView: panel)
			host.frame = NSRect(origin: .zero, size: host.fittingSize)
			let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
			window.contentView = host
			host.layoutSubtreeIfNeeded()
			let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
			host.cacheDisplay(in: host.bounds, to: rep)
			try #require(rep.representation(using: .png, properties: [:])).write(to: url)
		}
	}

	/// Renders `view` the way ``ContentView`` lays it out: fixed width, natural height.
	private func render(_ view: some View, model: AppModel, defaults: UserDefaults, to url: URL) throws {
		let root = view
			.padding(24)
			.fixedSize(horizontal: false, vertical: true)
			.frame(width: ContentView.width)
			.environment(model)
			.defaultAppStorage(defaults)
		let host = NSHostingView(rootView: root)
		let size = host.fittingSize
		host.frame = NSRect(origin: .zero, size: size)
		let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = host
		host.layoutSubtreeIfNeeded()
		let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: rep)
		try #require(rep.representation(using: .png, properties: [:])).write(to: url)
	}
}
