// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

struct SenderView: View {
	@Environment(AppModel.self) private var model
	@Bindable var session: SenderSession

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			RoleHeader(symbol: Role.sender.symbolName, title: "Extending this Mac", status: session.status.label, isActive: session.status.isConnected)

			if session.status == .needsPermission {
				PermissionCallout {
					session.stop()
					session.start()
				}
			}

			GroupBox {
				VStack(alignment: .leading, spacing: 10) {
					LabeledContent("Display", value: session.displayDescription)
					Picker("Shape", selection: $session.shape) {
						ForEach(DisplayShape.available(on: session.receiverPanel)) { Text($0.title(on: session.receiverPanel)).tag($0) }
					}
					.disabled(session.isRunning)
					LabeledContent("Thunderbolt Bridge", value: model.bridge.map { $0.isLinkUp ? "\($0.name) connected" : "\($0.name), no cable" } ?? "Not configured")
					if session.receivers.count > 1 {
						Picker("Receiver", selection: $session.preferredReceiver) {
							ForEach(session.receivers, id: \.self) { Text($0).tag(Optional($0)) }
						}
					}
				}
				.padding(6)
			}

			GroupBox {
				VStack(alignment: .leading, spacing: 10) {
					SenderStatsView(stats: session.stats)
					Toggle("Record statistics to a CSV file", isOn: $session.recordsStats)
						.font(.callout)
					if let url = session.recordingURL, session.recordsStats {
						Text(url.path(percentEncoded: false))
							.font(.caption)
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
					}
				}
				.padding(6)
				.frame(maxWidth: .infinity, alignment: .leading)
			}

			if let error = session.lastError {
				Text(error)
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			Spacer(minLength: 0)

			HStack {
				Button("Change Role") { model.reset() }
				Button("Arrange Displays…") {
					NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
				}
				Spacer()
				if session.isRunning {
					Button("Stop") { session.stop() }
				} else {
					Button("Start") { session.start() }
						.keyboardShortcut(.defaultAction)
				}
			}
		}
	}
}

private extension SenderSession.Status {
	var isConnected: Bool {
		if case .connected = self { return true }
		return false
	}
}

/// Title, status line, and a state light.
struct RoleHeader: View {
	let symbol: String
	let title: String
	let status: String
	let isActive: Bool

	var body: some View {
		HStack(spacing: 14) {
			Image(systemName: symbol)
				.font(.system(size: 30, weight: .light))
				.frame(width: 44)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.title2.weight(.semibold))
				HStack(spacing: 6) {
					Circle()
						.fill(isActive ? Color.green : Color.secondary.opacity(0.5))
						.frame(width: 8, height: 8)
					Text(status).foregroundStyle(.secondary)
				}
			}
		}
	}
}

private struct PermissionCallout: View {
	let retry: () -> Void

	var body: some View {
		GroupBox {
			VStack(alignment: .leading, spacing: 8) {
				Text("MokaScreen needs Screen Recording permission to read the extended display. Turn it on for MokaScreen in System Settings, then try again.")
					.fixedSize(horizontal: false, vertical: true)
				HStack {
					Button("Open Privacy Settings") {
						NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
					}
					Button("Try Again", action: retry)
				}
			}
			.padding(6)
		}
	}
}
