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
			}

			if showsStatistics {
				InfoSection {
					StatRow("Received", String(format: "%.0f fps  ·  %.2f Gbps", session.stats.receivedFPS, session.stats.gigabitsPerSecond))
					StatRow("Presented", String(format: "%.0f fps", session.stats.presentedFPS))
					StatRow("Arrival → on glass", session.stats.presentDelayP50 > 0 ? String(format: "%.1f ms p50  ·  %.1f ms p99", session.stats.presentDelayP50, session.stats.presentDelayP99) : "—")
					BridgeDetailRows(bridge: model.bridge)
				}
			}

			Text("When the other Mac connects, this screen switches to its display. Press Esc to stop showing it.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Spacer(minLength: 0)

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
