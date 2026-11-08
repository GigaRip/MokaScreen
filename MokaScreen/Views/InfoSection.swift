// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

/// A full-width rounded box of rows separated by dividers, in the style of a grouped form in
/// System Settings.
///
/// Used instead of `Form(.grouped)`, whose own scroll view and insets do not line up with the
/// header and buttons around it.
struct InfoSection<Content: View>: View {
	@ViewBuilder var content: Content

	var body: some View {
		VStack(spacing: 0) {
			Group(subviews: content) { rows in
				ForEach(rows) { row in
					if row.id != rows.first?.id {
						Divider()
					}
					row.padding(.vertical, 9)
				}
			}
		}
		.padding(.horizontal, 14)
		.frame(maxWidth: .infinity)
		.background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
	}
}

/// A label on the left and its value on the right.
struct InfoRow<Value: View>: View {
	let label: String
	@ViewBuilder var value: Value

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 16) {
			Text(label)
			Spacer(minLength: 0)
			value
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
				// Multi-line values such as the bridge addresses wrap instead of truncating.
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}

extension InfoRow where Value == Text {
	init(_ label: String, _ value: String) {
		self.label = label
		self.value = Text(value)
	}
}

extension Optional where Wrapped == BridgeState {
	/// The bridge's state in plain words.
	var summary: String {
		switch self {
		case nil: "Not set up"
		case let bridge?: bridge.isLinkUp ? "Connected" : "No cable"
		}
	}
}

/// The bridge's interface and addresses, for the statistics section.
struct BridgeDetailRows: View {
	let bridge: BridgeState?

	var body: some View {
		if let bridge {
			InfoRow("Bridge interface", "\(bridge.name) · index \(bridge.index)")
			if !bridge.addresses.isEmpty {
				InfoRow(label: "Addresses") {
					Text(bridge.addresses.joined(separator: "\n"))
						.textSelection(.enabled)
				}
			}
		}
	}
}
