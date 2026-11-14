// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

/// MokaScreen › Settings (⌘,). The display and statistics settings are kept the same on both
/// Macs while connected (see ``SettingsSync``); Developer mode belongs to this Mac only.
struct SettingsView: View {
	@AppStorage(SmoothMotionPreference.key) private var smoothMotion = SmoothMotionPreference.defaultValue
	@AppStorage(SmoothMotionFloorPreference.key) private var smoothMotionFloor = SmoothMotionFloorPreference.defaultValue
	@AppStorage(FixedRefreshRatePreference.key) private var fixedRefreshRate = FixedRefreshRatePreference.defaultValue
	@AppStorage(StatisticsPreference.key) private var showsStatistics = false
	@AppStorage(DeveloperModePreference.key) private var developerMode = false

	static let width: CGFloat = 500

	var body: some View {
		Form {
			Section {
				Toggle(isOn: $smoothMotion) {
					Text("Smooth Motion")
					Text("Shows each frame on the other MacBook spaced exactly as your Mac drew it, so scrolling stays even. Adds a little delay.")
				}
				Picker(selection: $smoothMotionFloor) {
					ForEach(SmoothMotionFloorPreference.choices, id: \.self) { millis in
						Text(millis == 0 ? "Adaptive" : "\(millis) ms").tag(millis)
					}
				} label: {
					Text("Smoothness margin")
					Text("More gives the slowest frames room to arrive on time; less keeps the pointer a touch snappier.")
				}
				.disabled(!smoothMotion)
				Toggle(isOn: $fixedRefreshRate) {
					Text("Hold the display at 120 Hz")
					Text("Keeps the other MacBook's screen at 120 Hz while it shows this Mac's display, so macOS never slows it to 60 Hz.")
				}
			} header: {
				Text("Display")
			}

			Section {
				Toggle(isOn: $showsStatistics) {
					Text("Show statistics")
					Text("Adds frame rates and the delay, part by part, to the MokaScreen window on the Mac you work on.")
				}
			} header: {
				Text("Statistics")
			} footer: {
				Text("Display and statistics settings are kept the same on both Macs.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}

			Section {
				Toggle(isOn: $developerMode) {
					Text("Developer mode")
					Text("Adds the Develop menu, with tools for measuring MokaScreen.")
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: Self.width)
		.fixedSize(horizontal: false, vertical: true)
	}
}
