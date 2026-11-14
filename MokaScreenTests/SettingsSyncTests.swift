// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Testing
@testable import MokaScreen

@MainActor
struct SettingsSyncTests {
	/// Two Macs' settings, each in a private defaults suite, connected so each one's sends reach
	/// the other's `receive`.
	@MainActor
	private final class Pair {
		let extending: UserDefaults
		let display: UserDefaults
		var extendingSync: SettingsSync!
		var displaySync: SettingsSync!
		var extendingSent: [SharedSettings] = []
		var displaySent: [SharedSettings] = []
		var displayChanges: [SharedSettings] = []

		init() throws {
			extending = try #require(UserDefaults(suiteName: "com.gigarip.mokascreen.tests.extending.\(UUID())"))
			display = try #require(UserDefaults(suiteName: "com.gigarip.mokascreen.tests.display.\(UUID())"))
			extendingSync = SettingsSync(defaults: extending, send: { [unowned self] settings in
				extendingSent.append(settings)
				displaySync.receive(settings)
			})
			displaySync = SettingsSync(defaults: display, send: { [unowned self] settings in
				displaySent.append(settings)
				extendingSync.receive(settings)
			}, onChange: { [unowned self] in displayChanges.append($0) })
		}
	}

	@Test func turningOnSmoothMotionWithStatisticsOnReachesTheOtherMacWithoutAnEcho() throws {
		let pair = try Pair()
		pair.extending.set(true, forKey: StatisticsPreference.key)
		pair.extending.set(true, forKey: SmoothMotionPreference.key)

		let both = SharedSettings(showsStatistics: true, smoothMotion: true)
		#expect(SharedSettings.load(from: pair.extending) == both)
		#expect(SharedSettings.load(from: pair.display) == both)
		#expect(pair.displaySent.isEmpty)
		#expect(pair.displayChanges.last == both)
	}

	@Test func aChangeOnTheDisplayMacReachesTheExtendingMac() throws {
		let pair = try Pair()
		pair.display.set(true, forKey: SmoothMotionPreference.key)

		let smooth = SharedSettings(showsStatistics: false, smoothMotion: true)
		#expect(SharedSettings.load(from: pair.extending) == smooth)
		#expect(pair.extendingSent.isEmpty)
		#expect(pair.displaySent == [smooth])
	}

	@Test func fixedRefreshRateIsOnUntilTurnedOffAndTravels() throws {
		let pair = try Pair()
		#expect(SharedSettings.load(from: pair.display).fixedRefreshRate)
		pair.extending.set(false, forKey: FixedRefreshRatePreference.key)

		let variable = SharedSettings(showsStatistics: false, smoothMotion: false, fixedRefreshRate: false)
		#expect(SharedSettings.load(from: pair.display) == variable)
		#expect(pair.displaySent.isEmpty)
		#expect(pair.displayChanges.last == variable)
	}
}
