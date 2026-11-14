// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

struct ReceiverView: View {
	@Environment(AppModel.self) private var model
	let session: ReceiverSession
	@AppStorage(StatisticsPreference.key) private var showsStatistics = false

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			RoleHeader(symbol: Role.receiver.symbolName, title: "Display for another Mac", status: session.status.label, isActive: session.status.isShowing)

			InfoSection {
				InfoRow("Appears as", session.serviceName)
				InfoRow("Thunderbolt", model.bridge.summary)
				if showsStatistics {
					BridgeDetailRows(bridge: model.bridge)
				}
			}

			Text("When the other Mac connects, this screen switches to its display. Switch to another app to pause it, or press Esc to stop.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			HStack {
				Button("Change Role") { model.reset() }
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

private extension ReceiverSession.Status {
	var isShowing: Bool {
		if case .showing = self { return true }
		return false
	}
}
