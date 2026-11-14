// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import os
import Sparkle
import SwiftUI

@main
struct MokaScreenApp: App {
	@State private var model = AppModel()
	@AppStorage(StatisticsPreference.key) private var showsStatistics = false
	@AppStorage(SmoothMotionPreference.key) private var smoothMotion = false
	@AppStorage(FixedRefreshRatePreference.key) private var fixedRefreshRate = FixedRefreshRatePreference.defaultValue

	/// Drives in-app updates via Sparkle. Held for the app's lifetime so the updater keeps
	/// running; `startingUpdater: true` begins checking for updates at launch.
	private let updaterController = SPUStandardUpdaterController(
		startingUpdater: true,
		updaterDelegate: nil,
		userDriverDelegate: nil
	)

	var body: some Scene {
		Window("MokaScreen", id: "main") {
			ContentView()
				.environment(model)
				.frame(width: ContentView.width)
				.task { model.launch() }
		}
		// The window takes exactly the content's size and follows it as rows, the statistics,
		// or the permission prompt come and go, so nothing is ever cut off.
		.windowResizability(.contentSize)
		.commands {
			CommandGroup(after: .appInfo) {
				CheckForUpdatesView(updater: updaterController.updater)
			}
			CommandMenu("Develop") {
				Button("Start Loopback Test") { model.startLoopback() }
					.disabled(model.isLoopback)
				Toggle("Show Statistics", isOn: $showsStatistics)
					.keyboardShortcut("s", modifiers: [.command, .option])
				Toggle("Smooth Motion", isOn: $smoothMotion)
					.keyboardShortcut("m", modifiers: [.command, .option])
				Toggle("Fixed 120 Hz", isOn: $fixedRefreshRate)
					.keyboardShortcut("r", modifiers: [.command, .option])
				Button("Show Latency Clock") { LatencyClock.toggle() }
					.keyboardShortcut("l", modifiers: [.command, .option])
				Divider()
				Button("Open Statistics Folder") {
					let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MokaScreen")
					try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
					NSWorkspace.shared.open(url)
				}
			}
		}
	}
}

/// Whether the windows show detailed statistics. Kept in user defaults, so once turned on it
/// stays on across launches until turned off.
enum StatisticsPreference {
	static let key = "showsStatistics"

	static var isOn: Bool {
		get { UserDefaults.standard.bool(forKey: key) }
		set { UserDefaults.standard.set(newValue, forKey: key) }
	}
}

/// Whether the display Mac paces frames to their capture times. Kept in user defaults like
/// ``StatisticsPreference``.
enum SmoothMotionPreference {
	static let key = "smoothMotion"

	static var isOn: Bool {
		get { UserDefaults.standard.bool(forKey: key) }
		set { UserDefaults.standard.set(newValue, forKey: key) }
	}
}

/// Whether the display Mac holds its screen at 120 Hz while showing. On by default: left to
/// choose, macOS sometimes ran the display Mac's ProMotion panel at 60 Hz under a steady 110 fps
/// load (see ``RefreshRateRequest``). Off lets ProMotion vary the rate, for experiments.
enum FixedRefreshRatePreference {
	static let key = "fixedRefreshRate"
	static let defaultValue = true

	static func isOn(in defaults: UserDefaults) -> Bool {
		defaults.object(forKey: key) as? Bool ?? defaultValue
	}
}

/// The settings both Macs keep the same while connected.
struct SharedSettings: Equatable {
	var showsStatistics: Bool
	var smoothMotion: Bool
	var fixedRefreshRate: Bool = FixedRefreshRatePreference.defaultValue

	/// This Mac's settings, from the standard user defaults.
	static var current: SharedSettings {
		get { load(from: .standard) }
		set { newValue.save(to: .standard) }
	}

	static func load(from defaults: UserDefaults) -> SharedSettings {
		SharedSettings(
			showsStatistics: defaults.bool(forKey: StatisticsPreference.key),
			smoothMotion: defaults.bool(forKey: SmoothMotionPreference.key),
			fixedRefreshRate: FixedRefreshRatePreference.isOn(in: defaults)
		)
	}

	func save(to defaults: UserDefaults) {
		defaults.set(showsStatistics, forKey: StatisticsPreference.key)
		defaults.set(smoothMotion, forKey: SmoothMotionPreference.key)
		defaults.set(fixedRefreshRate, forKey: FixedRefreshRatePreference.key)
	}
}

/// Keeps ``SharedSettings`` the same on both Macs while they are connected: a change on this Mac
/// is sent to the other, and one received from it is applied here without being sent back.
@MainActor
final class SettingsSync {
	private let defaults: UserDefaults
	private var observer: NSObjectProtocol?
	/// The settings last sent or received, so applying a received change does not echo it back.
	private var lastSeen: SharedSettings
	/// True while saving received settings. User defaults posts its change notification
	/// synchronously for each key saved, so between the two saves the settings read half-applied;
	/// sending that state back switched Smooth Motion off again on the Mac that turned it on.
	private var applying = false
	private let send: (SharedSettings) -> Void
	private let onChange: (SharedSettings) -> Void

	/// - Parameters:
	///   - defaults: Where the settings are kept; the standard user defaults except in tests.
	///   - send: Sends a change to the other Mac; does nothing when not connected.
	///   - onChange: Called after any change, made here or received.
	init(defaults: UserDefaults = .standard, send: @escaping (SharedSettings) -> Void, onChange: @escaping (SharedSettings) -> Void = { _ in }) {
		self.defaults = defaults
		self.send = send
		self.onChange = onChange
		lastSeen = SharedSettings.load(from: defaults)
		observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.localChange() }
		}
	}

	/// Applies the other Mac's settings here.
	func receive(_ settings: SharedSettings) {
		let changed = settings != SharedSettings.load(from: defaults)
		applying = true
		settings.save(to: defaults)
		applying = false
		lastSeen = settings
		if changed {
			onChange(settings)
		}
	}

	private func localChange() {
		guard !applying else { return }
		let settings = SharedSettings.load(from: defaults)
		guard settings != lastSeen else { return }
		lastSeen = settings
		send(settings)
		onChange(settings)
	}
}

/// Which side of the cable this Mac is on.
enum Role: String {
	/// The Mac you work on; its extended display is streamed out.
	case sender
	/// The Mac whose screen shows the other Mac's extended display.
	case receiver

	/// The SF Symbol for this role. `Image(systemName:)` draws nothing for an unknown name and
	/// reports no error, so the names are checked by a test.
	var symbolName: String {
		switch self {
		case .sender: "display.2"
		case .receiver: "display"
		}
	}
}

/// App-wide state: the chosen role, remembered across launches, and the session for it.
@MainActor
@Observable
final class AppModel {
	let sender = SenderSession()
	let receiver = ReceiverSession()
	private(set) var isLoopback = false
	/// The Thunderbolt Bridge as it is now, watched for as long as the app is open. Whether the
	/// Mac has a bridge and a cable does not depend on what either session is doing, so the
	/// views show this rather than a session's view of it.
	private(set) var bridge: BridgeState?
	@ObservationIgnored private var bridgeMonitor: BridgeMonitor?

	var role: Role? {
		didSet {
			UserDefaults.standard.set(role?.rawValue, forKey: "role")
		}
	}

	init() {
		role = UserDefaults.standard.string(forKey: "role").flatMap(Role.init)
		bridgeMonitor = BridgeMonitor { [weak self] state in
			guard let self else { return }
			self.bridge = state
			self.sender.bridgeChanged(state)
			self.receiver.bridgeChanged(state)
		}
	}

	/// Starts the remembered role, so a Mac set up once is ready as soon as MokaScreen opens.
	func launch() {
		// Unit tests run inside the app; they must not create displays or open sockets.
		guard NSClassFromString("XCTestCase") == nil else { return }
		if ProcessInfo.processInfo.arguments.contains("--loopback-test") {
			startLoopback()
		} else if let role {
			start(role)
		}
	}

	/// Switches this Mac to `role` and starts it.
	func start(_ role: Role) {
		stopAll()
		self.role = role
		switch role {
		case .sender: sender.start()
		case .receiver: receiver.start()
		}
	}

	/// Stops everything and forgets the role.
	func reset() {
		stopAll()
		role = nil
	}

	/// Runs sender and receiver in this one app over loopback, with the received display in a window.
	func startLoopback() {
		stopAll()
		do {
			try receiver.startLoopback()
			sender.start(loopback: true)
			isLoopback = true
		} catch {
			receiver.stop()
		}
	}

	/// Quits and opens MokaScreen again, which is how macOS applies a new Screen Recording
	/// permission. The new copy opens only once this one has exited, because two copies cannot
	/// both own the virtual display.
	func relaunch() {
		let reopen = Process()
		reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
		reopen.arguments = [
			"-c", #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$1""#,
			String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
		]
		do {
			try reopen.run()
		} catch {
			Log.app.error("Could not schedule the relaunch: \(error.localizedDescription, privacy: .public)")
			return
		}
		NSApp.terminate(nil)
	}

	func stopAll() {
		sender.stop()
		receiver.stop()
		isLoopback = false
	}
}
