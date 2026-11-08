// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import QuartzCore
import SwiftUI

/// A millisecond clock shown on every screen at once, for measuring glass-to-glass latency
/// (design spike 4): film both MacBooks with a high-speed camera and subtract the reading on
/// the receiver from the reading on the sender's own panel in the same video frame.
@MainActor
enum LatencyClock {
	private static var windows: [NSWindow] = []

	static func toggle() {
		if windows.isEmpty { show() } else { hide() }
	}

	private static func show() {
		for screen in NSScreen.screens {
			let size = NSSize(width: 760, height: 220)
			let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
			let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
			window.level = .floating
			window.isReleasedWhenClosed = false
			window.collectionBehavior = [.canJoinAllSpaces, .stationary]
			window.backgroundColor = .black
			window.contentView = NSHostingView(rootView: ClockFace(screenName: screen.localizedName))
			window.setFrame(NSRect(origin: origin, size: size), display: false)
			window.orderFrontRegardless()
			windows.append(window)
		}
	}

	private static func hide() {
		windows.forEach { $0.orderOut(nil) }
		windows.removeAll()
	}
}

private struct ClockFace: View {
	let screenName: String

	var body: some View {
		TimelineView(.animation) { _ in
			let millis = UInt64(CACurrentMediaTime() * 1000) % 100_000
			VStack(spacing: 4) {
				Text(String(format: "%02llu.%03llu", millis / 1000, millis % 1000))
					.font(.system(size: 140, weight: .bold, design: .monospaced))
				Text(screenName)
					.font(.system(size: 18, design: .monospaced))
					.opacity(0.7)
			}
			.foregroundStyle(.white)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(.black)
		}
	}
}
