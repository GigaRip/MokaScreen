// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import Testing
@testable import MokaScreen

@Suite struct InputMessageTests {
	private func roundTrip(_ message: InputMessage) throws -> InputMessage {
		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Wire.headerSize, alignment: 8)
		defer { buffer.deallocate() }
		message.encode(into: buffer)
		return try InputMessage.decode(buffer)
	}

	@Test func everyFieldSurvivesTheWire() throws {
		let messages = [
			InputMessage(kind: .keyDown, detail: 1, code: 53, flags: 0x10_0108),
			InputMessage(kind: .flagsChanged, code: 55, flags: CGEventFlags.maskCommand.rawValue),
			InputMessage(kind: .pointerMoved, flags: 0x100, x: -3.25, y: 117.5),
			InputMessage(kind: .buttonUp, detail: 2, code: 1),
			InputMessage(kind: .scroll, detail: 1, flags: 0x100, x: -1.4, y: 12.7, pointX: -14, pointY: 127, lineX: -1, lineY: 3, phase: 128, momentumPhase: 3),
			InputMessage(kind: .releaseAll),
		]
		for message in messages {
			#expect(try roundTrip(message) == message)
		}
	}

	@Test func theSharingSettingTravelsWithTheOthers() throws {
		let buffer = UnsafeMutableRawPointer.allocate(byteCount: Wire.headerSize, alignment: 8)
		defer { buffer.deallocate() }
		for shares in [false, true] {
			let settings = SharedSettings(showsStatistics: true, smoothMotion: false, forwardsInput: shares)
			SettingsMessage(settings: settings).encode(into: buffer)
			#expect(try SettingsMessage.decode(buffer).settings == settings)
		}
	}
}

@Suite struct HeldInputTests {
	@Test func everythingStillHeldIsLetGo() {
		var held = HeldInput()
		// ⌘ down, A down and up, then Tab taken by macOS: ⌘ is never reported released.
		held.note(InputMessage(kind: .flagsChanged, code: 55, flags: CGEventFlags.maskCommand.rawValue | 0x100))
		held.note(InputMessage(kind: .keyDown, code: 0))
		held.note(InputMessage(kind: .keyUp, code: 0))
		held.note(InputMessage(kind: .keyDown, code: 38))
		held.note(InputMessage(kind: .buttonDown, detail: 1, code: 0))
		#expect(held.releases() == [
			InputMessage(kind: .keyUp, code: 38),
			InputMessage(kind: .buttonUp, detail: 1, code: 0),
			InputMessage(kind: .flagsChanged, flags: 0),
		])
	}

	@Test func nothingHeldMeansNothingToLetGo() {
		var held = HeldInput()
		held.note(InputMessage(kind: .keyDown, code: 12))
		held.note(InputMessage(kind: .keyUp, code: 12))
		held.note(InputMessage(kind: .pointerMoved, x: 4, y: 4))
		// Caps Lock is a state, not a key held down.
		held.note(InputMessage(kind: .flagsChanged, code: 57, flags: CGEventFlags.maskAlphaShift.rawValue))
		#expect(held.isEmpty)
		#expect(held.releases().isEmpty)
	}

	@Test func aReleaseAllForgetsEverything() {
		var held = HeldInput()
		held.note(InputMessage(kind: .keyDown, code: 12))
		held.note(InputMessage(kind: .releaseAll))
		#expect(held.isEmpty)
	}
}

@Suite struct PointerMathTests {
	/// The built-in screen with the extended display to its left, as in Arrange Displays.
	private let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -1728, y: 0, width: 1728, height: 1117)]

	@Test func movesFreelyWithinAndBetweenDisplays() {
		#expect(PointerMath.destination(from: CGPoint(x: 100, y: 100), dx: 25, dy: -40, displays: displays) == CGPoint(x: 125, y: 60))
		#expect(PointerMath.destination(from: CGPoint(x: 5, y: 500), dx: -30, dy: 0, displays: displays) == CGPoint(x: -25, y: 500))
	}

	@Test func slidesAlongAnOuterEdge() {
		// Down and right at the bottom edge: the downward part is dropped, the rest kept.
		#expect(PointerMath.destination(from: CGPoint(x: 100, y: 1116), dx: 20, dy: 15, displays: displays) == CGPoint(x: 120, y: 1116))
		#expect(PointerMath.destination(from: CGPoint(x: 1727, y: 300), dx: 20, dy: 15, displays: displays) == CGPoint(x: 1727, y: 315))
	}

	@Test func staysPutInACorner() {
		let corner = CGPoint(x: 1727, y: 1116)
		#expect(PointerMath.destination(from: corner, dx: 9, dy: 9, displays: displays) == corner)
	}
}

@Suite struct InputCaptureTests {
	private func key(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
		try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: code))
	}

	@Test func commandEscapeLeavesAndPlainEscapeDoesNot() throws {
		#expect(InputCapture.isExitChord(try key(.keyDown, code: 53, flags: .command)))
		#expect(!InputCapture.isExitChord(try key(.keyDown, code: 53)))
		#expect(!InputCapture.isExitChord(try key(.keyUp, code: 53, flags: .command)))
		// ⌥⌘Esc is Force Quit, which macOS takes itself; it is not MokaScreen's chord.
		#expect(!InputCapture.isExitChord(try key(.keyDown, code: 53, flags: [.command, .option])))
		#expect(!InputCapture.isExitChord(try key(.keyDown, code: 12, flags: .command)))
		// Caps Lock being on does not get in the way.
		#expect(InputCapture.isExitChord(try key(.keyDown, code: 53, flags: [.command, .capsLock])))
	}

	@Test func keysAreForwardedByKeyCode() throws {
		let escape = InputCapture.disposition(for: try key(.keyDown, code: 53))
		guard case .forward(let down) = escape else {
			Issue.record("Esc was not forwarded")
			return
		}
		#expect(down.kind == .keyDown)
		#expect(down.code == 53)
		#expect(down.detail == 0)

		guard case .forward(let held) = InputCapture.disposition(for: try key(.keyDown, code: 0, isRepeat: true)) else {
			Issue.record("A repeat was not forwarded")
			return
		}
		#expect(held.detail == 1)

		guard case .forward(let up) = InputCapture.disposition(for: try key(.keyUp, code: 0)) else {
			Issue.record("A key up was not forwarded")
			return
		}
		#expect(up.kind == .keyUp)
	}

	@Test func pointerMovementIsForwardedAsADelta() throws {
		let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 400, y: 300), mouseButton: .left))
		cg.setIntegerValueField(.mouseEventDeltaX, value: 7)
		cg.setIntegerValueField(.mouseEventDeltaY, value: -3)
		let event = try #require(NSEvent(cgEvent: cg))
		guard case .forward(let moved) = InputCapture.disposition(for: event) else {
			Issue.record("A movement was not forwarded")
			return
		}
		#expect(moved.kind == .pointerMoved)
		#expect(moved.x == 7)
		#expect(moved.y == -3)
	}

	@Test func aTrackpadScrollKeepsItsPhases() throws {
		let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -24, wheel2: 3, wheel3: 0))
		cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
		cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
		cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
		let event = try #require(NSEvent(cgEvent: cg))
		guard case .forward(let scroll) = InputCapture.disposition(for: event) else {
			Issue.record("A scroll was not forwarded")
			return
		}
		#expect(scroll.kind == .scroll)
		#expect(scroll.detail == 1)
		#expect(scroll.pointY == -24)
		#expect(scroll.pointX == 3)
		#expect(scroll.phase == 2)
	}
}
