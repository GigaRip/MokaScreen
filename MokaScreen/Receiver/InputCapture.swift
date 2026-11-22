// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit

/// Turns the display Mac's keyboard and trackpad events into ``InputMessage``s for the Mac you
/// work on.
///
/// Only events MokaScreen's window is given are seen, so what macOS takes for itself stays with
/// the display Mac: ⌘Tab, Spotlight, Mission Control and the multi-finger swipes. That is the
/// way out to the display Mac's own apps, and it needs no Input Monitoring permission.
enum InputCapture {
	/// What to do with an event while forwarding.
	enum Disposition: Equatable {
		/// Send this to the other Mac and keep the event from AppKit.
		case forward(InputMessage)
		/// Keep the event from AppKit and send nothing: gestures that cannot be repeated on the
		/// other Mac (pinch, rotate, smart zoom, pressure).
		case swallow
		/// Not input; let AppKit have it.
		case pass
	}

	/// The key code of Esc.
	static let escapeKeyCode: UInt16 = 53

	/// ⌘Esc, which leaves MokaScreen. Plain Esc is forwarded like any other key; until 0.1.33 it
	/// was the way out, which would have kept it from every app on the other Mac.
	static func isExitChord(_ event: NSEvent) -> Bool {
		event.type == .keyDown && event.keyCode == escapeKeyCode
			&& event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
	}

	static func disposition(for event: NSEvent) -> Disposition {
		let flags = event.cgEvent?.flags.rawValue ?? 0
		switch event.type {
		case .keyDown:
			return .forward(InputMessage(kind: .keyDown, detail: event.isARepeat ? 1 : 0, code: event.keyCode, flags: flags))
		case .keyUp:
			return .forward(InputMessage(kind: .keyUp, code: event.keyCode, flags: flags))
		case .flagsChanged:
			return .forward(InputMessage(kind: .flagsChanged, code: event.keyCode, flags: flags))
		case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
			return .forward(InputMessage(kind: .pointerMoved, flags: flags, x: Float32(event.deltaX), y: Float32(event.deltaY)))
		case .leftMouseDown, .rightMouseDown, .otherMouseDown:
			return .forward(InputMessage(kind: .buttonDown, detail: UInt8(clamping: event.clickCount), code: UInt16(clamping: event.buttonNumber), flags: flags))
		case .leftMouseUp, .rightMouseUp, .otherMouseUp:
			return .forward(InputMessage(kind: .buttonUp, detail: UInt8(clamping: event.clickCount), code: UInt16(clamping: event.buttonNumber), flags: flags))
		case .scrollWheel:
			guard let cg = event.cgEvent else { return .swallow }
			// Read from the Core Graphics event, which is what the other Mac posts: the line, pixel
			// and fixed-point deltas and both phases, unchanged.
			return .forward(InputMessage(
				kind: .scroll,
				detail: cg.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 ? 1 : 0,
				flags: flags,
				x: Float32(cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)),
				y: Float32(cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)),
				pointX: Int16(clamping: cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
				pointY: Int16(clamping: cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
				lineX: Int8(clamping: cg.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
				lineY: Int8(clamping: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
				phase: UInt8(truncatingIfNeeded: cg.getIntegerValueField(.scrollWheelEventScrollPhase)),
				momentumPhase: UInt8(truncatingIfNeeded: cg.getIntegerValueField(.scrollWheelEventMomentumPhase))
			))
		case .magnify, .rotate, .swipe, .smartMagnify, .pressure, .gesture, .beginGesture, .endGesture, .quickLook, .directTouch, .tabletPoint, .tabletProximity:
			return .swallow
		default:
			return .pass
		}
	}
}
