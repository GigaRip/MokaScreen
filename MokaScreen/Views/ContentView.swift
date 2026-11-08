// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

struct ContentView: View {
	/// The window's fixed width; its height always fits the content.
	static let width: CGFloat = 560

	@Environment(AppModel.self) private var model

	var body: some View {
		Group {
			if model.isLoopback {
				LoopbackView()
			} else {
				switch model.role {
				case .sender: SenderView(session: model.sender)
				case .receiver: ReceiverView(session: model.receiver)
				case nil: RoleChooser()
				}
			}
		}
		.padding(24)
		.fixedSize(horizontal: false, vertical: true)
	}
}

private struct RoleChooser: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(spacing: 20) {
			Text("How will you use this Mac?")
				.font(.title2.weight(.semibold))
			Text("Connect your two MacBooks with a Thunderbolt cable, then pick a role on each.")
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			HStack(spacing: 16) {
				RoleButton(
					symbol: Role.sender.symbolName,
					title: "Extend this Mac",
					detail: "This is the Mac I work on. Add a display that appears on the other Mac."
				) { model.start(.sender) }
				RoleButton(
					symbol: Role.receiver.symbolName,
					title: "Be the display",
					detail: "Use this Mac's screen as the other Mac's extended display."
				) { model.start(.receiver) }
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 24)
	}
}

private struct RoleButton: View {
	let symbol: String
	let title: String
	let detail: String
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			VStack(spacing: 10) {
				Image(systemName: symbol)
					.font(.system(size: 40, weight: .light))
					.frame(height: 48)
				Text(title)
					.font(.headline)
				Text(detail)
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(20)
			.frame(width: 220, height: 200)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
	}
}

private struct LoopbackView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Loopback Test")
				.font(.title2.weight(.semibold))
			Text("This Mac is both sender and receiver. The MokaScreen display is captured, sent over a local TCP connection, and drawn in a window.")
				.foregroundStyle(.secondary)
			InfoSection {
				InfoRow("Sender", model.sender.status.label)
				InfoRow("Receiver", model.receiver.status.label)
				SenderStatsView(stats: model.sender.stats)
			}
			HStack {
				Spacer()
				Button("Stop") { model.stopAll() }
			}
		}
	}
}

/// A statistics row: an ``InfoRow`` with figures in tabular digits so they do not jitter as
/// they change every second.
struct StatRow: View {
	let label: String
	let value: String

	init(_ label: String, _ value: String) {
		self.label = label
		self.value = value
	}

	var body: some View {
		InfoRow(label: label) {
			Text(value).monospacedDigit()
		}
	}
}

/// The per-second rates behind the latency, as rows for an ``InfoSection``.
struct SenderStatsView: View {
	let stats: SenderSnapshot

	var body: some View {
		StatRow("Captured", String(format: "%.0f fps", stats.capturedFPS))
		StatRow("Sent", String(format: "%.0f fps  ·  %.2f Gbps", stats.sentFPS, stats.gigabitsPerSecond))
		StatRow("Shown on the display Mac", stats.displayPresentedFPS > 0 ? String(format: "%.0f fps", stats.displayPresentedFPS) : "—")
		StatRow("Changed area", String(format: "%.1f%% mean  ·  %.1f%% max", stats.meanCoverage * 100, stats.maxCoverage * 100))
		StatRow("Superseded", "\(stats.supersededFrames) frames")
	}
}

extension SenderSession.Status {
	var label: String {
		switch self {
		case .stopped: "Stopped"
		case .starting: "Creating the display…"
		case .needsPermission: "Needs Screen Recording permission"
		case .waitingForCable: "Waiting for a Thunderbolt connection"
		case .searching: "Looking for the other Mac…"
		case .connecting(let name): "Connecting to \(name)…"
		case .connected(let name): "Extending to \(name)"
		case .failed(let message): message
		}
	}
}

extension ReceiverSession.Status {
	var label: String {
		switch self {
		case .stopped: "Stopped"
		case .waitingForCable: "Waiting for a Thunderbolt connection"
		case .listening: "Ready — waiting for the other Mac"
		case .showing(let peer): "Showing \(peer)"
		case .failed(let message): message
		}
	}
}
