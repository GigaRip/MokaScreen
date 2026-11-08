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

/// The extending Mac's statistics panel, floating over every app in the bottom-right corner of
/// the built-in screen while Show Statistics is on.
///
/// It is placed on the built-in screen and never on the extended display, which is captured and
/// sent: there it would appear in the very picture it measures.
@MainActor
final class StatisticsWindow {
	/// Large enough for the panel at its tallest; the rest is transparent and click-through.
	private static let size = NSSize(width: 400, height: 480)
	private static let margin: CGFloat = 20

	private let panel: NSPanel
	private var observers: [NSObjectProtocol] = []

	init(session: SenderSession) {
		panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.isReleasedWhenClosed = false
		panel.hidesOnDeactivate = false
		// Above ordinary windows, below menus and alerts; on every Space, including full-screen ones.
		panel.level = .statusBar
		panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
		panel.contentView = NSHostingView(rootView: SenderStatisticsOverlay(session: session))

		let center = NotificationCenter.default
		observers = [
			center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.update() }
			},
			center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.update() }
			},
		]
		update()
	}

	/// Removes the panel for good.
	func close() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []
		panel.orderOut(nil)
	}

	private func update() {
		guard StatisticsPreference.isOn else {
			panel.orderOut(nil)
			return
		}
		let visible = NSScreen.builtIn.visibleFrame
		panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - Self.margin, y: visible.minY + Self.margin))
		panel.orderFrontRegardless()
	}
}

/// The panel, pinned to the bottom-right of its transparent window.
private struct SenderStatisticsOverlay: View {
	let session: SenderSession

	var body: some View {
		StatisticsPanel(content: StatisticsPanelContent(sender: session.stats, history: session.history, refreshRate: session.refreshRate ?? 120, display: session.displaySize))
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
	}
}
