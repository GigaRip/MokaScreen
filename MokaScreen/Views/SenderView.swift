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
	@AppStorage(StatisticsPreference.key) private var showsStatistics = false

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			RoleHeader(symbol: Role.sender.symbolName, title: "Extending this Mac", status: session.status.label, isActive: session.status.isConnected)

			if session.status == .needsPermission {
				PermissionCallout(reopen: model.relaunch)
			}

			InfoSection {
				if let performance = session.performanceSummary {
					InfoRow(label: "Performance") {
						Text(performance).monospacedDigit()
					}
				}
				InfoRow("Extended display", session.displayDescription)
				InfoRow(label: "Shape") {
					Picker("Shape", selection: $session.shape) {
						ForEach(DisplayShape.available(on: session.receiverPanel)) { Text($0.title(on: session.receiverPanel)).tag($0) }
					}
					.labelsHidden()
					.fixedSize()
					.disabled(session.isRunning)
				}
				InfoRow("Thunderbolt", model.bridge.summary)
				if session.receivers.count > 1 {
					InfoRow(label: "Display Mac") {
						Picker("Display Mac", selection: $session.preferredReceiver) {
							ForEach(session.receivers, id: \.self) { Text($0).tag(Optional($0)) }
						}
						.labelsHidden()
						.fixedSize()
					}
				}
			}

			if showsStatistics {
				// The rates and latency are in the floating statistics panel; the window keeps what
				// the panel does not show.
				InfoSection {
					StatRow("Superseded", "\(session.stats.supersededFrames) frames")
					BridgeDetailRows(bridge: model.bridge)
					InfoRow(label: "Record to a CSV file") {
						Toggle("Record to a CSV file", isOn: $session.recordsStats)
							.labelsHidden()
							.toggleStyle(.switch)
							.controlSize(.small)
					}
					if let url = session.recordingURL, session.recordsStats {
						Text(url.path(percentEncoded: false))
							.font(.caption)
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				}
			}

			if let error = session.lastError {
				Text(error)
					.font(.callout)
					.foregroundStyle(.secondary)
			}

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

/// Asks for Screen Recording permission. macOS applies a new grant only to a newly opened
/// app, so the second step is reopening MokaScreen rather than trying again in place.
private struct PermissionCallout: View {
	let reopen: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 14) {
			Image(systemName: "lock.display")
				.font(.system(size: 26))
				.foregroundStyle(.orange)
				.frame(width: 32)
			VStack(alignment: .leading, spacing: 10) {
				Text("Allow Screen Recording")
					.font(.headline)
				Text("MokaScreen reads the extended display with Screen Recording. Turn on MokaScreen in Privacy & Security › Screen & System Audio Recording, then reopen MokaScreen.")
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				HStack {
					Button("Open Privacy Settings") {
						NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
					}
					.buttonStyle(.borderedProminent)
					Button("Reopen MokaScreen", action: reopen)
				}
				.padding(.top, 2)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
	}
}
