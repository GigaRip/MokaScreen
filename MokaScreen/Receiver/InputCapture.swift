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

	/// How long Esc is held to leave MokaScreen.
	static let exitHoldSeconds = 1.0
	/// How long Esc is held before the hint appears, so that an ordinary press shows nothing.
	static let exitHintSeconds = 0.3

	/// ⌘Esc. 0.1.34 made it the way out, and on the one Mac it was tried on (macOS 27.2) pressing
	/// it did nothing; whether macOS keeps the key from apps is not known. It still leaves if it
	/// arrives. The way out that is known to arrive is holding Esc (see ``EscapeHold``).
	static func isExitChord(_ event: NSEvent) -> Bool {
		event.type == .keyDown && event.keyCode == escapeKeyCode
			&& event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
	}

	/// Whether `event` is Esc with no modifier that would make it another shortcut.
	static func isPlainEscape(_ event: NSEvent) -> Bool {
		(event.type == .keyDown || event.type == .keyUp) && event.keyCode == escapeKeyCode
			&& event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
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

/// Tells a press of Esc from a hold. A press goes to the other Mac at once, like any key; a hold
/// of ``InputCapture/exitHoldSeconds`` leaves MokaScreen. Esc is the exit because it is known to
/// reach MokaScreen's window, which no chord tried so far has been.
struct EscapeHold: Equatable {
	enum Action: Equatable {
		/// Esc went down: forward it and start timing the hold.
		case began
		/// An auto-repeat while held: keep it from the other Mac, which has its Esc already.
		case repeating
		/// Esc came up before the hold was long enough: forward it and stop timing.
		case ended
		/// A key up with no hold in progress, e.g. after leaving: forward it.
		case stray
	}

	private(set) var isHeld = false

	mutating func keyDown(isRepeat: Bool) -> Action {
		if isHeld || isRepeat {
			isHeld = true
			return .repeating
		}
		isHeld = true
		return .began
	}

	mutating func keyUp() -> Action {
		guard isHeld else { return .stray }
		isHeld = false
		return .ended
	}

	/// Forgets a hold, e.g. when the window stops being the key window mid-press.
	mutating func cancel() {
		isHeld = false
	}
}
