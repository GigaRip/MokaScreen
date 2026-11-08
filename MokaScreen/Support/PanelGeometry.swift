// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit

/// The screen a display Mac shows the extended display on, as the sender needs it to size the
/// virtual display so that every captured pixel lands on exactly one pixel of that screen.
///
/// The size is the screen's current mode ("looks like" points and backing scale), not the
/// panel's native resolution: the receiver renders into a drawable of that size, so matching
/// it is what makes the picture 1:1 — including when the display Mac uses a scaled mode.
struct PanelGeometry: Equatable, Codable, Sendable {
	/// Width in points.
	var width: Int
	/// Height in points, including the area beside the notch.
	var height: Int
	/// Backing scale factor: 2 on every Retina MacBook, which is the only HiDPI scale `CGVirtualDisplay` offers.
	var scale: Int
	/// Points at the top of the screen that the camera housing covers; 0 without a notch.
	var notchHeight: Int
	/// Physical size of the visible area, in millimetres.
	var widthMillimeters: Int
	var heightMillimeters: Int
	/// Highest refresh rate the screen supports, in hertz.
	var refreshRate: Int

	/// A 16-inch MacBook Pro at its default "1728 × 1117" mode — the shape used before any
	/// display Mac has been seen.
	static let macBookPro16 = PanelGeometry(width: 1728, height: 1117, scale: 2, notchHeight: 37, widthMillimeters: 346, heightMillimeters: 223, refreshRate: 120)

	/// Size in pixels.
	var pixelWidth: Int { width * scale }
	var pixelHeight: Int { height * scale }
}

// MARK: - Bonjour TXT fields

extension PanelGeometry {
	/// Bumped if the meaning of a field changes; a sender ignores geometry with another version.
	private static let txtVersion = "1"

	/// The geometry as the key/value pairs of the receiver's Bonjour TXT record.
	var txtFields: [String: String] {
		[
			"v": Self.txtVersion,
			"w": String(width),
			"h": String(height),
			"s": String(scale),
			"n": String(notchHeight),
			"mmw": String(widthMillimeters),
			"mmh": String(heightMillimeters),
			"hz": String(refreshRate),
		]
	}

	/// Reads geometry from a receiver's TXT record. Returns nil for a receiver that publishes
	/// none (an older build) or values no MacBook screen could have.
	init?(txtFields fields: [String: String]) {
		guard fields["v"] == Self.txtVersion,
		      let width = fields["w"].flatMap(Int.init), (640...8192).contains(width),
		      let height = fields["h"].flatMap(Int.init), (480...8192).contains(height),
		      let scale = fields["s"].flatMap(Int.init), (1...2).contains(scale),
		      let notch = fields["n"].flatMap(Int.init), (0..<height / 4).contains(notch),
		      let mmWidth = fields["mmw"].flatMap(Int.init), mmWidth > 0,
		      let mmHeight = fields["mmh"].flatMap(Int.init), mmHeight > 0,
		      let hz = fields["hz"].flatMap(Int.init), (24...240).contains(hz)
		else { return nil }
		self.init(width: width, height: height, scale: scale, notchHeight: notch, widthMillimeters: mmWidth, heightMillimeters: mmHeight, refreshRate: hz)
	}
}

// MARK: - Reading a screen

extension PanelGeometry {
	/// The geometry of `screen` in its current mode.
	@MainActor
	init(screen: NSScreen) {
		let width = Int(screen.frame.width.rounded())
		let height = Int(screen.frame.height.rounded())
		let scale = min(2, max(1, Int(screen.backingScaleFactor.rounded())))
		// Round the notch up so nothing the sender draws below it is clipped.
		let notch = Int(screen.safeAreaInsets.top.rounded(.up))
		let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
		let millimeters = displayID.map { CGDisplayScreenSize($0) } ?? .zero
		// CGDisplayScreenSize reports zero for displays without EDID size data; assume a
		// 254 ppi Retina panel, which is what every current MacBook Pro has.
		let fallback = 25.4 / 254 * Double(scale)
		self.init(
			width: width,
			height: height,
			scale: scale,
			notchHeight: notch,
			widthMillimeters: millimeters.width > 0 ? Int(millimeters.width.rounded()) : Int((Double(width) * fallback).rounded()),
			heightMillimeters: millimeters.height > 0 ? Int(millimeters.height.rounded()) : Int((Double(height) * fallback).rounded()),
			refreshRate: max(60, screen.maximumFramesPerSecond)
		)
	}
}
