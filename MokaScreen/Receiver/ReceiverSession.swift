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

/// Tells a real return to MokaScreen from macOS bouncing it forward.
///
/// On 2026-11-22 (macOS 27.2), ⌘Tab from the picture to System Settings or Safari hid the picture
/// and macOS made MokaScreen the active app again 43 and 50 ms later, so the picture came
/// straight back; ⌘Tab to Terminal did not. Why macOS returns the activation is not known.
/// Nobody switches away and back within a quarter of a second, so an activation that soon after
/// a hide is taken to be the bounce and handed back to the app the user chose.
enum ActivationBounce {
	static let windowNanos: UInt64 = 250_000_000

	static func isBounce(nanosSinceHidden: UInt64) -> Bool {
		nanosSinceHidden < windowNanos
	}
}

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
		/// Connected, but another app on this Mac is active, so the picture is hidden.
		case paused(peer: String)
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
	private(set) var stats = ReceiverSnapshot()

	/// The name this Mac advertises to senders.
	let serviceName = ReceiverSession.computerName()

	/// The latest bridge state from ``AppModel``, kept even while stopped so a start can act on it.
	@ObservationIgnored private var bridge: BridgeState?
	/// Whether bridge changes start and stop listening; true while started on the bridge.
	@ObservationIgnored private var followsBridge = false
	@ObservationIgnored private var listener: TCPListener?
	@ObservationIgnored private var advertiser: BonjourAdvertiser?
	@ObservationIgnored private var connection: Connection?
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var screenObserver: NSObjectProtocol?
	@ObservationIgnored private var presentation: Presentation = .fullScreen
	@ObservationIgnored private let receiverStats = ReceiverStats()
	@ObservationIgnored private var settingsSync: SettingsSync!
	/// When the picture was last hidden for another app, in host nanoseconds, and which app. See
	/// ``ActivationBounce``. Cleared by the next activation, so only the first one after a hide is
	/// ever handed back.
	@ObservationIgnored private var lastHidden: (time: UInt64, app: NSRunningApplication)?

	init() {
		settingsSync = SettingsSync(send: { [weak self] settings in
			self?.connection?.receiver.sendSettings(settings)
		}, onChange: { [weak self] settings in
			self?.connection?.renderer.smoothMotion = settings.smoothMotion
			self?.connection?.renderer.smoothMotionFloorMillis = settings.smoothMotionFloorMillis
			self?.updateRefreshRateRequest(fixed: settings.fixedRefreshRate)
			self?.updateInputForwarding()
		})
	}

	/// Everything that exists for one sender's connection.
	private final class Connection {
		let receiver: FrameReceiver
		let renderer: FrameRenderer
		var peer = ""
		var window: NSWindow?
		var view: MetalLayerView?
		var driver: PresentationDriver?
		var refreshRate: RefreshRateRequest?
		/// The panel's refreshes, noted by ``refreshRate`` and used by Smooth Motion.
		let ticks = DisplayTicks()
		/// The sender's clock, kept by ``receiver`` and used by Smooth Motion.
		let clock: ClockSync
		/// The sender's hello, kept so the window can be rebuilt.
		var hello: HelloMessage?
		/// When the window was last rebuilt because drawing was stuck, in host nanoseconds.
		var lastRebuild: UInt64 = 0
		var activity: NSObjectProtocol?
		var activationObservers: [NSObjectProtocol] = []

		init(receiver: FrameReceiver, renderer: FrameRenderer, clock: ClockSync) {
			self.receiver = receiver
			self.renderer = renderer
			self.clock = clock
		}
	}

	var isRunning: Bool { status != .stopped }

	/// Starts accepting a sender over the Thunderbolt Bridge.
	func start() {
		guard status == .stopped else { return }
		presentation = .fullScreen
		status = .waitingForCable
		followsBridge = true
		listenOnBridge()
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
		followsBridge = false
		if let screenObserver {
			NotificationCenter.default.removeObserver(screenObserver)
		}
		screenObserver = nil
		stopListening()
		disconnect()
		statsTimer?.invalidate()
		statsTimer = nil
		// Without the timer nothing refreshes the snapshot, so clear it rather than leave the
		// last second's rates on screen beside "Stopped".
		_ = receiverStats.drain()
		stats = ReceiverSnapshot()
		status = .stopped
	}

	private func startStatsTimer() {
		statsTimer?.invalidate()
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.stats = self.receiverStats.drain()
				self.stats.clockRoundTripMicros = self.connection?.clock.roundTripMicros ?? 0
				// The display Mac's window is hidden behind the picture while showing, so its
				// share of the delay is shown on the other Mac.
				if case .showing = self.status {
					self.connection?.receiver.sendReport(self.stats)
				}
			}
		}
	}

	/// Receives every change to the Thunderbolt Bridge from ``AppModel``, whether or not the
	/// session is running. Only a change of link or interface restarts listening.
	func bridgeChanged(_ state: BridgeState?) {
		let previous = bridge
		bridge = state
		guard followsBridge, state?.needsRestart(from: previous) ?? true else { return }
		listenOnBridge()
	}

	/// Restarts listening and advertising on the current bridge, or waits for a cable if it is not usable.
	private func listenOnBridge() {
		let state = bridge
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
		receiverStats.resetRecent()
		var connection: Connection!
		let clock = ClockSync()
		let receiver = FrameReceiver(stream: stream, sink: renderer, stats: receiverStats, clock: clock, onHello: { [weak self] hello in
			Task { @MainActor in
				guard let self, self.connection === connection else { return }
				self.show(connection, peer: stream.peerDescription, hello: hello)
			}
		}, onSettings: { [weak self] settings in
			Task { @MainActor in self?.settingsSync.receive(settings) }
		}, onTimingRequest: { [weak renderer] request in
			renderer?.recordTiming(for: Double(request.durationMillis) / 1000)
		}, onClose: { [weak self] error in
			Log.transport.info("Sender disconnected: \(String(describing: error), privacy: .public)")
			Task { @MainActor in
				guard let self, self.connection === connection else { return }
				self.disconnect()
			}
		})
		connection = Connection(receiver: receiver, renderer: renderer, clock: clock)
		renderer.clock = clock
		renderer.smoothMotion = SmoothMotionPreference.isOn(in: .standard)
		renderer.smoothMotionFloorMillis = SmoothMotionFloorPreference.millis(in: .standard)
		renderer.onPresented = { [weak receiver] frameID, glassTime in
			receiver?.reportPresented(frameID: frameID, glassTime: glassTime)
		}
		renderer.displayTicks = connection.ticks
		renderer.onFrameTiming = { [weak receiver] timing in
			receiver?.sendFrameTiming(timing)
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
			// ⌘Esc means "give me my screen back": stop listening too, or the sender would
			// reconnect within a second and take the screen over again.
			fullScreen.onExit = { [weak self] in self?.stop() }
			fullScreen.onInput = { [weak connection] input in connection?.receiver.sendInput(input) }
			// Pointer movement with no button held reaches a window only if it asks.
			fullScreen.acceptsMouseMovedEvents = true
			fullScreen.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
			fullScreen.setFrame(screen.frame, display: false)
			window = fullScreen
		case .window:
			window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Int(hello.width) / 4, height: Int(hello.height) / 4), styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
			window.title = "MokaScreen Loopback"
			window.contentAspectRatio = NSSize(width: Int(hello.width), height: Int(hello.height))
			window.center()
		}
		window.isReleasedWhenClosed = false
		window.backgroundColor = .black
		// Nothing is drawn above the Metal layer, so WindowServer can show it directly instead of
		// compositing the window, which would add a refresh of latency.
		window.contentView = view

		let driver = PresentationDriver(layer: view.metalLayer, renderer: connection.renderer)
		driver.onSlowDrawable = { [weak self, weak connection] milliseconds, gotDrawable, stuck in
			Task { @MainActor in
				guard let self, let connection else { return }
				self.drawableWasSlow(connection, milliseconds: milliseconds, gotDrawable: gotDrawable, stuck: stuck)
			}
		}
		connection.hello = hello
		connection.peer = peer
		connection.window = window
		connection.view = view
		connection.driver = driver

		switch presentation {
		case .fullScreen:
			// The hidden menu bar and Dock apply only while MokaScreen is the active app; with
			// another app active, its menu bar and windows would be drawn over the picture. So the
			// picture is shown only while MokaScreen is active and paused otherwise.
			driver.setPaused(true)
			driver.start()
			status = .paused(peer: peer)
			let center = NotificationCenter.default
			connection.activationObservers = [
				center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.pause() }
				},
				center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.resume() }
				},
			]
			// A connection can arrive while another app is active, e.g. a reconnect after sleep.
			// macOS may decline the activation; the picture then appears when the user switches
			// back to MokaScreen.
			if NSApp.isActive {
				resume()
			} else {
				Log.app.notice("Asking macOS to bring MokaScreen forward for a connection from \(peer, privacy: .public) (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown", privacy: .public))")
				NSApp.activate()
			}
		case .window:
			driver.start()
			beginShowing(connection)
		}
	}

	/// The least time between rebuilds, so a display that stays stuck does not flash a new window
	/// every second.
	private static let rebuildIntervalNanos: UInt64 = 10_000_000_000

	/// Records a slow `nextDrawable()` in the system log with the state macOS reports for the
	/// window and screen, and rebuilds the window when drawing is stuck. See
	/// ``DrawableStallDetector``.
	private func drawableWasSlow(_ connection: Connection, milliseconds: Double, gotDrawable: Bool, stuck: Bool) {
		guard self.connection === connection, let window = connection.window else { return }
		let screen = window.screen
		let size = connection.view?.metalLayer.drawableSize ?? .zero
		let headroom = Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0)
		let potentialHeadroom = Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0)
		Log.stall.notice("Drawable took \(milliseconds, format: .fixed(precision: 0), privacy: .public) ms (\(gotDrawable ? "returned" : "timed out", privacy: .public)\(stuck ? ", stuck" : "", privacy: .public)): window visible \(window.isVisible, privacy: .public), occlusion visible \(window.occlusionState.contains(.visible), privacy: .public), app active \(NSApp.isActive, privacy: .public), status \(String(describing: self.status), privacy: .public); screen \(screen?.maximumFramesPerSecond ?? 0, privacy: .public) Hz, EDR headroom \(headroom, format: .fixed(precision: 2), privacy: .public) of \(potentialHeadroom, format: .fixed(precision: 1), privacy: .public); drawable \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public)")
		// Only while this Mac's user is looking at the picture. Another app's window covering it
		// slows drawing in the same way, and rebuilding then would bring MokaScreen back in front
		// of the app the user had just switched to.
		guard stuck, case .showing = status, NSApp.isActive, window.isVisible, let hello = connection.hello else { return }
		let now = HostClock.now
		guard connection.lastRebuild == 0 || now &- connection.lastRebuild >= Self.rebuildIntervalNanos else { return }
		connection.lastRebuild = now
		Log.stall.notice("Drawing is stuck; rebuilding the window")
		rebuildPresentation(connection, hello: hello)
	}

	/// Replaces the window, its Metal layer and the render thread, keeping the connection and the
	/// picture received so far: what a reconnect does for the presentation, without the reconnect.
	private func rebuildPresentation(_ connection: Connection, hello: HelloMessage) {
		for observer in connection.activationObservers {
			NotificationCenter.default.removeObserver(observer)
		}
		connection.activationObservers = []
		endShowing(connection)
		connection.driver?.stop()
		connection.driver = nil
		connection.window = nil
		connection.view = nil
		show(connection, peer: connection.peer, hello: hello)
		connection.renderer.setNeedsRedraw()
	}

	/// Hides the picture while another app is active. Frames keep arriving and are applied, so
	/// the sender is not held up and resuming shows the newest image.
	private func pause() {
		guard let connection, case .showing(let peer) = status else { return }
		let chosen = NSWorkspace.shared.frontmostApplication
		endShowing(connection)
		status = .paused(peer: peer)
		if let chosen, chosen != .current {
			lastHidden = (HostClock.now, chosen)
		}
		// Notice level, kept on disk, with what MokaScreen is left showing: its own window taking
		// over as key window is one thing that might draw the activation back.
		Log.app.notice("Picture hidden: \(chosen?.localizedName ?? "another app", privacy: .public) is active; MokaScreen's key window is now \(NSApp.keyWindow?.title ?? "none", privacy: .public), \(NSApp.windows.filter(\.isVisible).count, privacy: .public) of its windows visible")
	}

	private func resume() {
		guard let connection, case .paused = status else { return }
		if let hidden = lastHidden {
			lastHidden = nil
			let elapsed = HostClock.now &- hidden.time
			if ActivationBounce.isBounce(nanosSinceHidden: elapsed), !hidden.app.isTerminated {
				// Give the user the app they chose. Without the yield macOS treats the activation
				// as a request it may decline, since MokaScreen is the active app.
				Log.app.notice("MokaScreen was made active again \(elapsed / 1_000_000, privacy: .public) ms after \(hidden.app.localizedName ?? "another app", privacy: .public) was chosen; handing back to it")
				NSApp.yieldActivation(to: hidden.app)
				hidden.app.activate(from: .current, options: [])
				return
			}
		}
		beginShowing(connection)
		Log.app.notice("Picture shown again: MokaScreen became the active app (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown", privacy: .public))")
	}

	private func beginShowing(_ connection: Connection) {
		guard let window = connection.window, let view = connection.view else { return }
		if presentation == .fullScreen {
			NSApp.presentationOptions = [.hideDock, .hideMenuBar]
			NSCursor.hide()
		}
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()
		connection.renderer.refreshInterval = 1 / Double(max(60, window.screen?.maximumFramesPerSecond ?? 120))
		if FixedRefreshRatePreference.isOn(in: .standard) {
			connection.refreshRate = RefreshRateRequest(view: view, ticks: connection.ticks)
		}
		// A display must not dim or sleep while it is someone else's screen.
		connection.activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical], reason: "Showing another Mac's display")
		connection.driver?.setPaused(false)
		status = .showing(peer: connection.peer)
		updateInputForwarding()
	}

	/// Holds or releases the display at 120 Hz while showing, as Settings › Hold the display at 120 Hz changes.
	private func updateRefreshRateRequest(fixed: Bool) {
		guard let connection, case .showing = status, let view = connection.view else { return }
		if fixed, connection.refreshRate == nil {
			connection.refreshRate = RefreshRateRequest(view: view, ticks: connection.ticks)
		} else if !fixed, let request = connection.refreshRate {
			request.invalidate()
			connection.refreshRate = nil
		}
		Log.render.info("Fixed 120 Hz \(fixed ? "on" : "off", privacy: .public)")
	}

	/// Starts or stops sending this Mac's keyboard and trackpad to the other Mac, to match
	/// Settings › Share the keyboard and trackpad and whether the picture is showing.
	private func updateInputForwarding() {
		guard let connection, let window = connection.window as? FullScreenWindow else { return }
		var forwards = false
		if case .showing = status {
			forwards = InputForwardingPreference.isOn(in: .standard)
		}
		setInputForwarding(forwards, for: connection, window: window)
	}

	private func setInputForwarding(_ forwards: Bool, for connection: Connection, window: FullScreenWindow) {
		guard window.forwardsInput != forwards else { return }
		window.forwardsInput = forwards
		// While forwarding, this Mac's own pointer stays where it is: trackpad movement still
		// arrives as deltas, but the hidden pointer cannot wander into a hot corner or the Dock.
		CGAssociateMouseAndMouseCursorPosition(forwards ? 0 : 1)
		if !forwards {
			// The other Mac must not be left holding a key this Mac will never report released,
			// such as ⌘ after ⌘Tab took the picture away.
			connection.receiver.sendInput(InputMessage(kind: .releaseAll))
		}
	}

	private func endShowing(_ connection: Connection) {
		if let window = connection.window as? FullScreenWindow {
			setInputForwarding(false, for: connection, window: window)
		}
		connection.driver?.setPaused(true)
		connection.refreshRate?.invalidate()
		connection.refreshRate = nil
		if let activity = connection.activity {
			ProcessInfo.processInfo.endActivity(activity)
		}
		connection.activity = nil
		connection.window?.orderOut(nil)
		if presentation == .fullScreen {
			NSApp.presentationOptions = []
			NSCursor.unhide()
		}
	}

	private func disconnect() {
		guard let connection else { return }
		self.connection = nil
		for observer in connection.activationObservers {
			NotificationCenter.default.removeObserver(observer)
		}
		connection.activationObservers = []
		if case .showing = status {
			endShowing(connection)
		} else {
			connection.window?.orderOut(nil)
		}
		connection.receiver.stop()
		connection.renderer.shutDown()
		connection.driver?.stop()
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

	private static func builtInScreen() -> NSScreen {
		NSScreen.builtIn
	}

	private static func computerName() -> String {
		(SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
	}
}
