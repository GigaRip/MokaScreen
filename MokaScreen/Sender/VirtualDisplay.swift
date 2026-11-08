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
import os

/// Which part of the display Mac's screen the extended display covers.
enum DisplayShape: String, CaseIterable, Identifiable {
	/// The whole screen, like the built-in display's own mode. The virtual display does not
	/// know about the receiver's notch, so a sliver of its menu bar sits behind it.
	case fullPanel
	/// The area below the notch. The receiver shows a black band where the notch is.
	case belowNotch

	var id: String { rawValue }

	/// Size in points of the virtual display for this shape on `panel`.
	func pointSize(on panel: PanelGeometry) -> (width: Int, height: Int) {
		switch self {
		case .fullPanel: (panel.width, panel.height)
		case .belowNotch: (panel.width, panel.height - panel.notchHeight)
		}
	}

	/// Size in pixels of the virtual display for this shape on `panel`.
	func pixelSize(on panel: PanelGeometry) -> (width: Int, height: Int) {
		let points = pointSize(on: panel)
		return (points.width * panel.scale, points.height * panel.scale)
	}

	/// The shapes that differ on `panel`; a screen without a notch has only one.
	static func available(on panel: PanelGeometry) -> [DisplayShape] {
		panel.notchHeight > 0 ? allCases : [.fullPanel]
	}

	/// A menu title with the resulting pixel size.
	func title(on panel: PanelGeometry) -> String {
		let pixels = pixelSize(on: panel)
		let size = "\(pixels.width) × \(pixels.height)"
		switch self {
		case .fullPanel: return "Full screen (\(size))"
		case .belowNotch: return "Below the notch (\(size))"
		}
	}
}

/// Errors creating the virtual display.
enum VirtualDisplayError: Error, CustomStringConvertible {
	case creationFailed
	case settingsRejected
	case modeUnavailable

	var description: String {
		switch self {
		case .creationFailed: "macOS refused to create the virtual display"
		case .settingsRejected: "macOS rejected the virtual display's modes"
		case .modeUnavailable: "macOS did not offer the requested display mode"
		}
	}
}

/// A HiDPI display that exists only in software, created with the private `CGVirtualDisplay` API.
///
/// To macOS it is an ordinary extended display: windows, Spaces, the menu bar, and System
/// Settings › Displays all treat it as real. It exists for the lifetime of this object.
final class VirtualDisplay {
	/// The display's CoreGraphics ID, for ScreenCaptureKit and display configuration.
	let displayID: CGDirectDisplayID
	/// The receiver screen this display is sized for.
	let panel: PanelGeometry
	let shape: DisplayShape
	let refreshRate: Double
	let pointSize: (width: Int, height: Int)
	let pixelSize: (width: Int, height: Int)
	private let display: CGVirtualDisplay

	/// Creates a display that maps 1:1 onto `panel` in the given shape, at the panel's refresh
	/// rate capped at 120 Hz. Call ``activate()`` before capturing from it.
	/// - Parameter onTerminate: Called if WindowServer tears the display down on its own.
	init(panel: PanelGeometry, shape: DisplayShape, onTerminate: @escaping @Sendable () -> Void) throws {
		self.panel = panel
		self.shape = shape
		refreshRate = Double(min(panel.refreshRate, 120))
		let points = shape.pointSize(on: panel)
		let pixels = shape.pixelSize(on: panel)
		pointSize = points
		pixelSize = pixels

		let descriptor = CGVirtualDisplayDescriptor()
		descriptor.queue = DispatchQueue(label: "com.gigarip.mokascreen.virtual-display")
		descriptor.name = "MokaScreen"
		descriptor.maxPixelsWide = UInt32(pixels.width)
		descriptor.maxPixelsHigh = UInt32(pixels.height)
		// The receiver's physical size, so macOS picks sensible defaults and text is the same
		// size on both screens. Below the notch, only that part of the panel is covered.
		descriptor.sizeInMillimeters = CGSize(
			width: Double(panel.widthMillimeters),
			height: Double(panel.heightMillimeters) * Double(points.height) / Double(panel.height)
		)
		// macOS keys a display's arrangement, mode, and color profile on vendor/product/serial.
		// Fixed values make it remember where the user put MokaScreen across launches.
		descriptor.vendorID = 0x4D4B
		descriptor.productID = 0x5343
		descriptor.serialNum = 1
		// Display P3 primaries and D65 white, matching the receiver's panel, so wide-gamut content
		// is not clipped to sRGB before it is captured.
		descriptor.redPrimary = CGPoint(x: 0.680, y: 0.320)
		descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.690)
		descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
		descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
		descriptor.terminationHandler = { _, _ in
			Log.display.error("WindowServer terminated the virtual display")
			onTerminate()
		}

		guard let display = CGVirtualDisplay(descriptor: descriptor) else {
			throw VirtualDisplayError.creationFailed
		}
		let settings = CGVirtualDisplaySettings()
		// With hiDPI set, mode sizes are in points and each mode is offered at twice that in pixels.
		settings.hiDPI = panel.scale > 1 ? 1 : 0
		settings.modes = Set([refreshRate, 60]).sorted(by: >).map {
			CGVirtualDisplayMode(width: UInt32(points.width), height: UInt32(points.height), refreshRate: $0)
		}
		guard display.apply(settings) else {
			throw VirtualDisplayError.settingsRejected
		}
		self.display = display
		self.displayID = display.displayID
		Log.display.info("Created virtual display \(self.displayID, privacy: .public): \(points.width, privacy: .public)×\(points.height, privacy: .public) pt, \(pixels.width, privacy: .public)×\(pixels.height, privacy: .public) px, \(Int(self.refreshRate), privacy: .public) Hz (\(shape.rawValue, privacy: .public))")
	}

	/// Waits for WindowServer to publish the display's modes, then switches it to the HiDPI mode
	/// at the requested refresh rate.
	///
	/// macOS remembers a per-display mode choice, so a previous "More Space" selection in
	/// System Settings would otherwise persist and change the capture size under the receiver.
	func activate() async throws {
		let pixels = pixelSize
		let points = pointSize
		for _ in 0..<40 {
			let modes = Self.modes(of: displayID)
			if let target = modes.first(where: {
				$0.pixelWidth == pixels.width && $0.pixelHeight == pixels.height
					&& $0.width == points.width && $0.height == points.height
					&& abs($0.refreshRate - refreshRate) < 0.5
			}) {
				logModes(modes)
				if let current = CGDisplayCopyDisplayMode(displayID), Self.same(current, target) {
					return
				}
				var config: CGDisplayConfigRef?
				CGBeginDisplayConfiguration(&config)
				CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
				let error = CGCompleteDisplayConfiguration(config, .forSession)
				if error != .success {
					Log.display.error("Could not set display mode: \(error.rawValue, privacy: .public)")
				}
				return
			}
			try await Task.sleep(for: .milliseconds(50))
		}
		throw VirtualDisplayError.modeUnavailable
	}

	/// A one-line description of the display's current mode.
	var currentModeDescription: String {
		guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "—" }
		let hiDPI = mode.pixelWidth > mode.width ? " HiDPI" : ""
		return "\(mode.width) × \(mode.height)\(hiDPI) · \(Int(mode.refreshRate.rounded())) Hz"
	}

	/// Current size of the display in pixels, which is the capture size.
	var currentPixelSize: (width: Int, height: Int) {
		guard let mode = CGDisplayCopyDisplayMode(displayID) else { return pixelSize }
		return (mode.pixelWidth, mode.pixelHeight)
	}

	private static func modes(of displayID: CGDirectDisplayID) -> [CGDisplayMode] {
		let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
		return (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
	}

	private static func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
		a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight && a.width == b.width
			&& a.height == b.height && abs(a.refreshRate - b.refreshRate) < 0.5
	}

	private func logModes(_ modes: [CGDisplayMode]) {
		let usable = modes.filter { $0.isUsableForDesktopGUI() && $0.pixelWidth > $0.width }
		let list = usable.map { "\($0.width)×\($0.height)@\(Int($0.refreshRate.rounded()))" }.joined(separator: ", ")
		Log.display.info("HiDPI modes offered for display \(self.displayID, privacy: .public): \(list, privacy: .public)")
	}
}
