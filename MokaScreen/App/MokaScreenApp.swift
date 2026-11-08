// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Sparkle
import SwiftUI

@main
struct MokaScreenApp: App {
	@State private var model = AppModel()

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
				.frame(minWidth: 520, minHeight: 440)
				.task { model.launch() }
		}
		.windowResizability(.contentSize)
		.defaultSize(width: 560, height: 520)
		.commands {
			CommandGroup(after: .appInfo) {
				CheckForUpdatesView(updater: updaterController.updater)
			}
			CommandMenu("Develop") {
				Button("Start Loopback Test") { model.startLoopback() }
					.disabled(model.isLoopback)
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

/// Which side of the cable this Mac is on.
enum Role: String {
	/// The Mac you work on; its extended display is streamed out.
	case sender
	/// The Mac whose screen shows the other Mac's extended display.
	case receiver
}

/// App-wide state: the chosen role, remembered across launches, and the session for it.
@MainActor
@Observable
final class AppModel {
	let sender = SenderSession()
	let receiver = ReceiverSession()
	private(set) var isLoopback = false

	var role: Role? {
		didSet {
			UserDefaults.standard.set(role?.rawValue, forKey: "role")
		}
	}

	init() {
		role = UserDefaults.standard.string(forKey: "role").flatMap(Role.init)
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

	func stopAll() {
		sender.stop()
		receiver.stop()
		isLoopback = false
	}
}
