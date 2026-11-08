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
		let model = AppModel()
		for showsStatistics in [false, true] {
			// A private defaults suite, so the app's real "Show Statistics" setting is untouched.
			let defaults = try #require(UserDefaults(suiteName: "com.gigarip.mokascreen.snapshots"))
			defaults.set(showsStatistics, forKey: StatisticsPreference.key)
			let suffix = showsStatistics ? "-statistics" : ""
			try render(SenderView(session: model.sender), model: model, defaults: defaults, to: directory.appending(path: "sender\(suffix).png"))
			try render(ReceiverView(session: model.receiver), model: model, defaults: defaults, to: directory.appending(path: "receiver\(suffix).png"))
		}
	}

	private func render(_ view: some View, model: AppModel, defaults: UserDefaults, to url: URL) throws {
		let size = NSSize(width: 560, height: 560)
		let host = NSHostingView(rootView: view.padding(24).frame(width: size.width, height: size.height).environment(model).defaultAppStorage(defaults))
		host.frame = NSRect(origin: .zero, size: size)
		let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = host
		host.layoutSubtreeIfNeeded()
		let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: rep)
		try #require(rep.representation(using: .png, properties: [:])).write(to: url)
	}
}
