// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreGraphics
import Foundation
import Testing
@testable import MokaScreen

struct PanelGeometryTests {
	/// A 14-inch MacBook Pro at its default "1512 × 982" mode.
	private let macBookPro14 = PanelGeometry(width: 1512, height: 982, scale: 2, notchHeight: 37, widthMillimeters: 302, heightMillimeters: 196, refreshRate: 120)

	@Test func txtRecordRoundTrips() {
		let fields = ["w": "1512", "h": "982", "empty": "", "text": "a=b=c"]
		#expect(TXTRecord.decode(TXTRecord.encode(fields)) == fields)
	}

	@Test func txtRecordFollowsRFC6763() {
		// Length-prefixed strings; keys are case-insensitive and the first occurrence wins;
		// a key without "=" is present with an empty value.
		var data = Data()
		for entry in ["A=1", "a=2", "flag", "=novalue", "b=x"] {
			data.append(UInt8(entry.utf8.count))
			data.append(contentsOf: Array(entry.utf8))
		}
		#expect(TXTRecord.decode(data) == ["a": "1", "flag": "", "b": "x"])
		#expect(TXTRecord.encode([:]) == Data([0]))
	}

	@Test func txtRecordStopsAtTruncation() {
		let data = Data([3]) + Data("w=1".utf8) + Data([9]) + Data("h=9".utf8)
		#expect(TXTRecord.decode(data) == ["w": "1"])
	}

	@Test func geometryRoundTripsThroughTXT() {
		for panel in [PanelGeometry.macBookPro16, macBookPro14] {
			let data = TXTRecord.encode(panel.txtFields)
			#expect(PanelGeometry(txtFields: TXTRecord.decode(data)) == panel)
		}
	}

	@Test func geometryRejectsOlderAndImplausibleRecords() {
		#expect(PanelGeometry(txtFields: [:]) == nil)
		var fields = macBookPro14.txtFields
		fields["v"] = "2"
		#expect(PanelGeometry(txtFields: fields) == nil)
		fields = macBookPro14.txtFields
		fields["s"] = "3"
		#expect(PanelGeometry(txtFields: fields) == nil)
		fields = macBookPro14.txtFields
		fields["w"] = "wide"
		#expect(PanelGeometry(txtFields: fields) == nil)
		fields = macBookPro14.txtFields
		fields.removeValue(forKey: "hz")
		#expect(PanelGeometry(txtFields: fields) == nil)
	}

	@Test func shapesMatchEachPanel() {
		#expect(DisplayShape.fullPanel.pixelSize(on: .macBookPro16) == (3456, 2234))
		#expect(DisplayShape.belowNotch.pixelSize(on: .macBookPro16) == (3456, 2160))
		#expect(DisplayShape.fullPanel.pixelSize(on: macBookPro14) == (3024, 1964))
		#expect(DisplayShape.belowNotch.pixelSize(on: macBookPro14) == (3024, 1890))
	}

	@Test func screensWithoutNotchOfferOneShape() {
		var panel = macBookPro14
		panel.notchHeight = 0
		#expect(DisplayShape.available(on: panel) == [.fullPanel])
		#expect(DisplayShape.available(on: macBookPro14) == DisplayShape.allCases)
	}

	@Test func receiverRendersEveryShapeOneToOne() {
		// The receiver's drawable is its screen in pixels; each shape must fit it unscaled.
		for panel in [PanelGeometry.macBookPro16, macBookPro14] {
			for shape in DisplayShape.allCases {
				let pixels = shape.pixelSize(on: panel)
				let fit = FrameRenderer.fit(width: pixels.width, height: pixels.height, into: panel.pixelWidth, panel.pixelHeight)
				#expect(fit.isOneToOne)
				#expect(fit.viewport.originY == Double(panel.pixelHeight - pixels.height))
			}
		}
	}

	/// Creates real virtual displays, which briefly adds a screen to this Mac, so it runs only
	/// when asked for: `TEST_RUNNER_MOKASCREEN_DISPLAY_TESTS=1 xcodebuild … test`. Quit any
	/// other copy of MokaScreen first: macOS refuses a second display with the same vendor,
	/// product, and serial number.
	@Test(.enabled(if: ProcessInfo.processInfo.environment["MOKASCREEN_DISPLAY_TESTS"] == "1"))
	@MainActor func macOSOffersTheModeForEachPanel() async throws {
		for panel in [PanelGeometry.macBookPro16, macBookPro14] {
			for shape in DisplayShape.allCases {
				let display = try VirtualDisplay(panel: panel, shape: shape) {}
				try await display.activate()
				let size = display.currentPixelSize
				#expect(size == shape.pixelSize(on: panel), "\(shape) on \(panel.width)×\(panel.height)")
				#expect(display.currentModeDescription.hasSuffix("120 Hz"))
			}
		}
	}
}
