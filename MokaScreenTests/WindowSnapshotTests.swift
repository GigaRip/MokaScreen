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
		// Forty seconds of a connection: idle at first, then a busy stretch.
		var history: [SenderSnapshot] = []
		for second in 0..<40 {
			var snapshot = SenderSnapshot()
			snapshot.interval = 1
			let busy = second >= 8
			snapshot.capturedFrames = busy ? 120 : 0
			snapshot.sentFrames = busy ? 118 : 0
			snapshot.bytes = busy ? 300_000_000 : 0
			snapshot.meanCoverage = busy ? 0.031 : 0
			snapshot.maxCoverage = busy ? 0.2 : 0
			let wobble = sin(Double(second) / 5) * 1.2
			snapshot.recentLatency = second < 2 ? 0 : 8.5 + wobble * 0.5
			snapshot.recentLatencyP99 = second < 2 ? 0 : 16 + abs(wobble)
			snapshot.latencyMax = busy ? 31 : 0
			snapshot.displayDelay = second < 3 ? 0 : 6.5 + wobble * 0.3
			snapshot.displayDelayP99 = second < 3 ? 0 : 12
			snapshot.displayPresentedFPS = busy ? 118 : 0
			history.append(snapshot)
		}
		let senderStates: [(String, SenderSession.Status, Int?, [SenderSnapshot])] = [
			("stopped", .stopped, nil, []),
			("permission", .needsPermission, nil, []),
			("connected", .connected("Brian's MacBook Pro"), 120, history),
		]
		for showsStatistics in [false, true] {
			defaults.set(showsStatistics, forKey: StatisticsPreference.key)
			let suffix = showsStatistics ? "-statistics" : ""
			for (name, status, refreshRate, history) in senderStates {
				model.sender.applySnapshotState(status: status, refreshRate: refreshRate, stats: history.last ?? SenderSnapshot(), history: history)
				try render(SenderView(session: model.sender), model: model, defaults: defaults, to: directory.appending(path: "sender-\(name)\(suffix).png"))
			}
			try render(ReceiverView(session: model.receiver), model: model, defaults: defaults, to: directory.appending(path: "receiver\(suffix).png"))
		}
		model.sender.applySnapshotState(status: .stopped)
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
