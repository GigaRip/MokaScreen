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

/// The display Mac's statistics, drawn over the full-screen picture while Show Statistics is on.
///
/// The view is hidden, not just empty, while the setting is off: any visible view above the
/// Metal layer makes WindowServer composite the window instead of showing the layer directly,
/// which can cost a frame of latency.
final class StatisticsOverlayView: NSHostingView<StatisticsOverlay> {
	private var observer: NSObjectProtocol?

	@MainActor
	init(session: ReceiverSession) {
		super.init(rootView: StatisticsOverlay(session: session))
		updateVisibility()
		observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.updateVisibility() }
		}
	}

	@available(*, unavailable)
	required init(rootView: StatisticsOverlay) {
		fatalError()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError()
	}

	deinit {
		if let observer { NotificationCenter.default.removeObserver(observer) }
	}

	/// Clicks pass through to the picture; the overlay is for reading only.
	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override var acceptsFirstResponder: Bool { false }

	private func updateVisibility() {
		isHidden = !StatisticsPreference.isOn
	}
}

/// Places the ``StatisticsPanel`` in the bottom-right corner, clear of the notch.
struct StatisticsOverlay: View {
	let session: ReceiverSession

	var body: some View {
		StatisticsPanel(content: StatisticsPanelContent(receiver: session.stats, history: session.history, refreshRate: session.displayRate, source: session.sourceSize))
			.padding(28)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
	}
}
