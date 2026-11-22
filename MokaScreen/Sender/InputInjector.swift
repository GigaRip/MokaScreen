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

/// Where the pointer goes when it is moved by a forwarded movement.
enum PointerMath {
	/// The point `dx`, `dy` from `point`, kept on a display. A move that would leave every display
	/// is tried along each axis alone, so the pointer slides along an outer edge instead of
	/// sticking where it first touched it.
	static func destination(from point: CGPoint, dx: CGFloat, dy: CGFloat, displays: [CGRect]) -> CGPoint {
		func onADisplay(_ p: CGPoint) -> Bool {
			displays.contains { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }
		}
		for candidate in [CGPoint(x: point.x + dx, y: point.y + dy), CGPoint(x: point.x + dx, y: point.y), CGPoint(x: point.x, y: point.y + dy)] where onADisplay(candidate) {
			return candidate
		}
		return point
	}
}

/// The keys, buttons and modifiers the display Mac is holding down, so they can all be let go
/// when it stops forwarding. The display Mac cannot always send the release itself: ⌘Tab sends
/// ⌘ down, then macOS takes Tab, MokaScreen is no longer active, and ⌘ up never reaches it.
struct HeldInput: Equatable {
	/// The modifier bits of `CGEventFlags`, without Caps Lock, which is a state and not a hold.
	static let modifierMask: UInt64 = CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).rawValue

	private(set) var keys: Set<UInt16> = []
	private(set) var buttons: Set<UInt16> = []
	private(set) var modifiers: UInt64 = 0

	var isEmpty: Bool { keys.isEmpty && buttons.isEmpty && modifiers == 0 }

	mutating func note(_ message: InputMessage) {
		switch message.kind {
		case .keyDown: keys.insert(message.code)
		case .keyUp: keys.remove(message.code)
		case .buttonDown: buttons.insert(message.code)
		case .buttonUp: buttons.remove(message.code)
		case .flagsChanged: modifiers = message.flags & Self.modifierMask
		case .pointerMoved, .scroll: break
		case .releaseAll: self = HeldInput()
		}
	}

	/// The messages that let go of everything held, in the order to post them.
	func releases() -> [InputMessage] {
		var result = keys.sorted().map { InputMessage(kind: .keyUp, code: $0) }
		result += buttons.sorted().map { InputMessage(kind: .buttonUp, detail: 1, code: $0) }
		if modifiers != 0 {
			result.append(InputMessage(kind: .flagsChanged, flags: 0))
		}
		return result
	}
}

/// Repeats the display Mac's keyboard and trackpad events on this Mac, as if a second keyboard
/// and trackpad were attached to it: one pointer, one keyboard focus.
///
/// Posting events needs the Accessibility permission. Events are posted at the HID level, where
/// hardware events enter, so shortcuts and the cursor behave as they do for this Mac's own
/// devices. Pointer movement arrives already shaped by the display Mac's tracking speed. Key
/// codes are forwarded, not characters, so this Mac's keyboard layout applies. Pinch, rotate and
/// the other gestures have no public event to post and are not forwarded.
final class InputInjector: @unchecked Sendable {
	private let lock = NSLock()
	private let source: CGEventSource?
	private var held = HeldInput()
	private var enabled = false

	init() {
		source = CGEventSource(stateID: .hidSystemState)
		// Posting an event otherwise suppresses this Mac's own keyboard and trackpad for a quarter
		// of a second, which would make the two sets of devices fight.
		source?.localEventsSuppressionInterval = 0
	}

	/// Whether this Mac lets MokaScreen post events (Privacy & Security › Accessibility).
	static var hasPermission: Bool { CGPreflightPostEventAccess() }

	/// Asks macOS to show its prompt for the permission, once; later calls do nothing visible.
	static func requestPermission() {
		_ = CGRequestPostEventAccess()
	}

	/// Whether events are posted. Turning it off lets go of anything held.
	var isEnabled: Bool {
		get { lock.withLock { enabled } }
		set {
			lock.lock()
			let wasEnabled = enabled
			enabled = newValue
			lock.unlock()
			if wasEnabled && !newValue {
				releaseAll()
			}
		}
	}

	/// Posts one event from the display Mac. Called on the connection's reader thread.
	func handle(_ message: InputMessage) {
		lock.lock()
		defer { lock.unlock() }
		guard enabled || message.kind == .releaseAll else { return }
		if message.kind == .releaseAll {
			release()
			return
		}
		held.note(message)
		post(message)
	}

	/// Lets go of every key, button and modifier the display Mac was holding, e.g. when the
	/// connection ends.
	func releaseAll() {
		lock.withLock { release() }
	}

	/// Caller holds `lock`.
	private func release() {
		for message in held.releases() {
			post(message)
		}
		held = HeldInput()
	}

	private var pointerLocation: CGPoint {
		CGEvent(source: nil)?.location ?? .zero
	}

	private static func displayBounds() -> [CGRect] {
		var count: UInt32 = 0
		CGGetActiveDisplayList(0, nil, &count)
		var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
		CGGetActiveDisplayList(count, &ids, &count)
		return ids.prefix(Int(count)).map(CGDisplayBounds)
	}

	/// Caller holds `lock`.
	private func post(_ message: InputMessage) {
		let flags = CGEventFlags(rawValue: message.flags)
		let event: CGEvent?
		switch message.kind {
		case .keyDown, .keyUp:
			event = CGEvent(keyboardEventSource: source, virtualKey: message.code, keyDown: message.kind == .keyDown)
			event?.setIntegerValueField(.keyboardEventAutorepeat, value: Int64(message.detail))
		case .flagsChanged:
			event = CGEvent(keyboardEventSource: source, virtualKey: message.code, keyDown: true)
			event?.type = .flagsChanged
		case .pointerMoved:
			let target = PointerMath.destination(from: pointerLocation, dx: CGFloat(message.x), dy: CGFloat(message.y), displays: Self.displayBounds())
			// A movement with a button held is a drag of that button, as it is from hardware.
			let (type, button): (CGEventType, CGMouseButton) = held.buttons.contains(0) ? (.leftMouseDragged, .left)
				: held.buttons.contains(1) ? (.rightMouseDragged, .right)
				: held.buttons.isEmpty ? (.mouseMoved, .left) : (.otherMouseDragged, .center)
			event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button)
			event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(message.x.rounded()))
			event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(message.y.rounded()))
		case .buttonDown, .buttonUp:
			let down = message.kind == .buttonDown
			let (type, button): (CGEventType, CGMouseButton) = switch message.code {
			case 0: (down ? .leftMouseDown : .leftMouseUp, .left)
			case 1: (down ? .rightMouseDown : .rightMouseUp, .right)
			default: (down ? .otherMouseDown : .otherMouseUp, .center)
			}
			event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pointerLocation, mouseButton: button)
			event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(message.code))
			event?.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, message.detail)))
		case .scroll:
			event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(message.pointY), wheel2: Int32(message.pointX), wheel3: 0)
			event?.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(message.lineY))
			event?.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(message.lineX))
			event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(message.y))
			event?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(message.x))
			event?.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(message.pointY))
			event?.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(message.pointX))
			event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: Int64(message.detail))
			event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(message.phase))
			event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(message.momentumPhase))
		case .releaseAll:
			event = nil
		}
		guard let event else { return }
		event.flags = flags
		event.post(tap: .cghidEventTap)
	}
}
