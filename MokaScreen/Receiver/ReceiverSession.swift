// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import Observation
import os
import SystemConfiguration

/// Runs this Mac as a display for another Mac.
@MainActor
@Observable
final class ReceiverSession {
	/// What the receiver is doing.
	enum Status: Equatable {
		case stopped
		case waitingForCable
		case listening
		case showing(peer: String)
		case failed(String)
	}

	/// How received frames are shown.
	enum Presentation {
		/// Full screen on the built-in display; the normal mode.
		case fullScreen
		/// In an ordinary window, for the single-Mac loopback test.
		case window
	}

	private(set) var status: Status = .stopped
	private(set) var bridge: BridgeState?
	private(set) var stats = ReceiverSnapshot()
	/// The name this Mac advertises to senders.
	let serviceName = ReceiverSession.computerName()

	@ObservationIgnored private var monitor: BridgeMonitor?
	@ObservationIgnored private var listener: TCPListener?
	@ObservationIgnored private var advertiser: BonjourAdvertiser?
	@ObservationIgnored private var connection: Connection?
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var screenObserver: NSObjectProtocol?
	@ObservationIgnored private var presentation: Presentation = .fullScreen
	@ObservationIgnored private let receiverStats = ReceiverStats()

	/// Everything that exists for one sender's connection.
	private final class Connection {
		let receiver: FrameReceiver
		let renderer: FrameRenderer
		var window: NSWindow?
		var driver: DisplayLinkDriver?
		var activity: NSObjectProtocol?

		init(receiver: FrameReceiver, renderer: FrameRenderer) {
			self.receiver = receiver
			self.renderer = renderer
		}
	}

	var isRunning: Bool { status != .stopped }

	/// Starts accepting a sender over the Thunderbolt Bridge.
	func start() {
		guard status == .stopped else { return }
		presentation = .fullScreen
		status = .waitingForCable
		monitor = BridgeMonitor { [weak self] state in
			self?.bridgeChanged(state)
		}
		// The sender sizes its virtual display from the advertised geometry, so a resolution
		// change here must reach it before its next connection.
		screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.advertiser?.update(txt: Self.panelGeometry().txtFields)
			}
		}
		startStatsTimer()
	}

	/// Starts accepting a sender on this Mac only, shown in a window. For testing without a second Mac.
	func startLoopback() throws {
		stop()
		presentation = .window
		listener = try TCPListener(port: Wire.port, scope: .loopback) { [weak self] stream in
			Task { @MainActor in self?.accept(stream) }
		}
		status = .listening
		startStatsTimer()
	}

	/// Disconnects and stops listening.
	func stop() {
		monitor?.stop()
		monitor = nil
		if let screenObserver {
			NotificationCenter.default.removeObserver(screenObserver)
		}
		screenObserver = nil
		stopListening()
		disconnect()
		statsTimer?.invalidate()
		statsTimer = nil
		status = .stopped
	}

	private func startStatsTimer() {
		statsTimer?.invalidate()
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.stats = self.receiverStats.drain()
			}
		}
	}

	private func bridgeChanged(_ state: BridgeState?) {
		let previous = bridge
		bridge = state
		guard listener == nil || state?.needsRestart(from: previous) ?? true else { return }
		stopListening()
		guard let state, state.isUsable else {
			if connection == nil { status = .waitingForCable }
			return
		}
		do {
			listener = try TCPListener(port: Wire.port, scope: .interface(state.index)) { [weak self] stream in
				Task { @MainActor in self?.accept(stream) }
			}
			advertiser = try BonjourAdvertiser(name: serviceName, port: Wire.port, interfaceIndex: state.index, txt: Self.panelGeometry().txtFields)
			if connection == nil { status = .listening }
			Log.transport.info("Listening on \(state.name, privacy: .public) (index \(state.index, privacy: .public))")
		} catch {
			stopListening()
			status = .failed(String(describing: error))
		}
	}

	private func stopListening() {
		listener?.stop()
		listener = nil
		advertiser = nil
	}

	private func accept(_ stream: TCPStream) {
		Log.transport.info("Sender connected from \(stream.peerDescription, privacy: .public)")
		// A new connection replaces the old one: after sleep or a cable swap the sender reconnects
		// before this side has noticed the old socket is dead.
		disconnect()
		let renderer: FrameRenderer
		do {
			renderer = try FrameRenderer(stats: receiverStats)
		} catch {
			stream.close()
			status = .failed(String(describing: error))
			return
		}
		var connection: Connection!
		let receiver = FrameReceiver(stream: stream, sink: renderer, stats: receiverStats, onHello: { [weak self] hello in
			Task { @MainActor in
				guard let self, self.connection === connection else { return }
				self.show(connection, peer: stream.peerDescription, hello: hello)
			}
		}, onClose: { [weak self] error in
			Log.transport.info("Sender disconnected: \(String(describing: error), privacy: .public)")
			Task { @MainActor in
				guard let self, self.connection === connection else { return }
				self.disconnect()
			}
		})
		connection = Connection(receiver: receiver, renderer: renderer)
		renderer.onPresented = { [weak receiver] frameID in
			receiver?.reportPresented(frameID: frameID)
		}
		self.connection = connection
		receiver.start()
	}

	private func show(_ connection: Connection, peer: String, hello: HelloMessage) {
		let view = MetalLayerView(device: connection.renderer.device)
		view.onDrawableResize = { [weak renderer = connection.renderer] in renderer?.setNeedsRedraw() }

		let window: NSWindow
		switch presentation {
		case .fullScreen:
			let screen = Self.builtInScreen()
			let fullScreen = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
			// Esc means "give me my screen back": stop listening too, or the sender would
			// reconnect within a second and take the screen over again.
			fullScreen.onExit = { [weak self] in self?.stop() }
			fullScreen.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
			fullScreen.setFrame(screen.frame, display: false)
			window = fullScreen
			NSApp.presentationOptions = [.hideDock, .hideMenuBar]
			NSCursor.hide()
		case .window:
			window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Int(hello.width) / 4, height: Int(hello.height) / 4), styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
			window.title = "MokaScreen Loopback"
			window.contentAspectRatio = NSSize(width: Int(hello.width), height: Int(hello.height))
			window.center()
		}
		window.isReleasedWhenClosed = false
		window.backgroundColor = .black
		window.contentView = view
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()

		let driver = DisplayLinkDriver(layer: view.metalLayer, renderer: connection.renderer)
		driver.start()
		connection.window = window
		connection.driver = driver
		// A display must not dim or sleep while it is someone else's screen.
		connection.activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical], reason: "Showing another Mac's display")
		status = .showing(peer: peer)
	}

	private func disconnect() {
		guard let connection else { return }
		self.connection = nil
		connection.receiver.stop()
		connection.renderer.shutDown()
		connection.driver?.stop()
		if let activity = connection.activity {
			ProcessInfo.processInfo.endActivity(activity)
		}
		if let window = connection.window {
			window.orderOut(nil)
			if presentation == .fullScreen {
				NSApp.presentationOptions = []
				NSCursor.unhide()
			}
		}
		if status != .stopped {
			status = listener != nil ? .listening : .waitingForCable
		}
	}

	/// The geometry of the screen received frames are shown on.
	private static func panelGeometry() -> PanelGeometry {
		let geometry = PanelGeometry(screen: builtInScreen())
		Log.transport.info("Advertising screen \(geometry.width, privacy: .public)×\(geometry.height, privacy: .public) pt @\(geometry.scale, privacy: .public)x, notch \(geometry.notchHeight, privacy: .public) pt, \(geometry.refreshRate, privacy: .public) Hz")
		return geometry
	}

	/// The built-in panel if there is one, else the main screen.
	private static func builtInScreen() -> NSScreen {
		NSScreen.screens.first { screen in
			guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
			return CGDisplayIsBuiltin(number.uint32Value) != 0
		} ?? NSScreen.main ?? NSScreen.screens[0]
	}

	private static func computerName() -> String {
		(SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
	}
}
