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

/// Runs this Mac as the one you work on: creates the extended display and streams it to a receiver.
@MainActor
@Observable
final class SenderSession {
	/// What the sender is doing.
	enum Status: Equatable {
		case stopped
		case starting
		case needsPermission
		case waitingForCable
		case searching
		case connecting(String)
		case connected(String)
		case failed(String)
	}

	private(set) var status: Status = .stopped
	private(set) var receivers: [String] = []
	private(set) var displayDescription = "Off"
	/// Refresh rate of the virtual display, while it exists.
	private(set) var refreshRate: Int?
	private(set) var stats = SenderSnapshot()
	private(set) var lastError: String?
	private(set) var recordingURL: URL?

	/// Receiver to prefer when several are visible; remembered across launches.
	var preferredReceiver: String? {
		didSet { UserDefaults.standard.set(preferredReceiver, forKey: "preferredReceiver") }
	}

	/// Shape of the virtual display. Takes effect on the next start.
	var shape: DisplayShape {
		didSet { UserDefaults.standard.set(shape.rawValue, forKey: "displayShape") }
	}

	/// The screen of the display Mac last connected to. The virtual display is created at this
	/// size so that reconnecting to the same Mac never has to rebuild it.
	private(set) var receiverPanel: PanelGeometry {
		didSet { UserDefaults.standard.set(try? JSONEncoder().encode(receiverPanel), forKey: "receiverPanel") }
	}

	/// Write one CSV row per second of activity to `~/Library/Logs/MokaScreen`.
	var recordsStats = false {
		didSet { updateRecorder() }
	}

	@ObservationIgnored private var display: VirtualDisplay?
	@ObservationIgnored private var capturer: ScreenCapturer?
	/// The latest bridge state from ``AppModel``, kept even while stopped so a start can act on it.
	@ObservationIgnored private var bridge: BridgeState?
	/// Whether bridge changes start and stop discovery; true once the display is up.
	@ObservationIgnored private var followsBridge = false
	@ObservationIgnored private var browser: BonjourBrowser?
	@ObservationIgnored private var connectTask: Task<Void, Never>?
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var recorder: StatsRecorder?
	@ObservationIgnored private var loopback = false
	/// Identifies the current virtual display, so a termination callback from one that has
	/// already been replaced is ignored.
	@ObservationIgnored private var displayGeneration = 0
	@ObservationIgnored private let senderStats = SenderStats()
	@ObservationIgnored private let link = CaptureLink()
	@ObservationIgnored private var settingsSync: SettingsSync!
	/// The last minute of per-second statistics while connected, oldest first.
	private(set) var history: [SenderSnapshot] = []
	/// The virtual display's size in pixels, such as "3456 × 2234", while it exists.
	private(set) var displaySize: String?

	init() {
		shape = UserDefaults.standard.string(forKey: "displayShape").flatMap(DisplayShape.init) ?? .fullPanel
		preferredReceiver = UserDefaults.standard.string(forKey: "preferredReceiver")
		receiverPanel = UserDefaults.standard.data(forKey: "receiverPanel").flatMap { try? JSONDecoder().decode(PanelGeometry.self, from: $0) } ?? .macBookPro16
		settingsSync = SettingsSync(send: { [link] settings in link.sendSettings(settings) })
	}

	var isRunning: Bool { status != .stopped }

	#if DEBUG
	/// Puts the session in a state for window snapshots, without a display or a connection.
	func applySnapshotState(status: Status, refreshRate: Int? = nil, stats: SenderSnapshot = SenderSnapshot(), history: [SenderSnapshot] = []) {
		self.status = status
		self.refreshRate = refreshRate
		self.stats = stats
		self.history = history
	}
	#endif

	/// One line for the main window while connected, such as "120 Hz · 8.4 ms delay": the
	/// display's refresh rate and the typical time from capture to the other Mac's screen.
	var performanceSummary: String? {
		guard case .connected = status, let refreshRate else { return nil }
		let delay = stats.recentLatency
		guard delay > 0 else { return "\(refreshRate) Hz" }
		let milliseconds = delay < 10 ? String(format: "%.1f", delay) : String(format: "%.0f", delay)
		return "\(refreshRate) Hz  ·  \(milliseconds) ms delay"
	}

	/// Creates the virtual display, starts capturing it, and connects to a receiver over the
	/// Thunderbolt Bridge — or, with `loopback`, to a receiver in this same app.
	func start(loopback: Bool = false) {
		guard status == .stopped else { return }
		self.loopback = loopback
		status = .starting
		lastError = nil
		startStatsTimer()
		Task {
			do {
				try await startDisplayAndCapture()
			} catch CaptureError.permissionDenied {
				teardownDisplay()
				status = .needsPermission
				return
			} catch {
				teardownDisplay()
				status = .failed(String(describing: error))
				return
			}
			if loopback {
				status = .searching
				startConnecting()
			} else {
				status = .waitingForCable
				followsBridge = true
				browseBridge()
			}
		}
	}

	/// Disconnects and removes the virtual display.
	func stop() {
		connectTask?.cancel()
		connectTask = nil
		link.setSender(nil)
		followsBridge = false
		browser?.stop()
		browser = nil
		receivers = []
		statsTimer?.invalidate()
		statsTimer = nil
		history = []
		// Without the timer nothing refreshes the snapshot, so clear it rather than leave the
		// last second's rates on screen beside "Stopped".
		_ = senderStats.drain()
		stats = SenderSnapshot()
		teardownDisplay()
		status = .stopped
	}

	private func startDisplayAndCapture() async throws {
		displayGeneration += 1
		let generation = displayGeneration
		let display = try VirtualDisplay(panel: receiverPanel, shape: shape) { [weak self] in
			Task { @MainActor in self?.displayTerminated(generation: generation) }
		}
		self.display = display
		try await display.activate()
		displayDescription = display.currentModeDescription
		refreshRate = Int(display.refreshRate.rounded())
		displaySize = "\(display.pixelSize.width) × \(display.pixelSize.height)"
		try await startCapture()
	}

	private func startCapture() async throws {
		guard let display else { return }
		let size = display.currentPixelSize
		let link = link
		let stats = senderStats
		let auditor = DirtyRectAuditor.isEnabled ? DirtyRectAuditor() : nil
		let capturer = ScreenCapturer(displayID: display.displayID, width: size.width, height: size.height, onFrame: { frame in
			stats.recordCaptured()
			auditor?.audit(frame)
			link.deliver(frame)
		}, onStop: { [weak self] error in
			Task { @MainActor in self?.captureStopped(error) }
		})
		link.reset()
		try await capturer.start()
		self.capturer = capturer
	}

	private func teardownDisplay() {
		let capturer = capturer
		self.capturer = nil
		Task { await capturer?.stop() }
		link.reset()
		display = nil
		displayDescription = "Off"
		refreshRate = nil
		displaySize = nil
	}

	/// Replaces the virtual display with one sized for `panel`.
	///
	/// macOS moves the old display's windows to another screen when it disappears; the new one
	/// has the same vendor, product, and serial number, so it takes the old one's place in the
	/// arrangement.
	private func rebuildDisplay(for panel: PanelGeometry) async throws {
		Log.display.info("Resizing the virtual display for a \(panel.width, privacy: .public)×\(panel.height, privacy: .public) pt screen")
		receiverPanel = panel
		let capturer = capturer
		self.capturer = nil
		link.reset()
		await capturer?.stop()
		display = nil
		displayDescription = "Off"
		try await startDisplayAndCapture()
		// stop() may have run while this was suspended.
		guard isRunning, !Task.isCancelled else {
			teardownDisplay()
			throw CancellationError()
		}
	}

	private func displayTerminated(generation: Int) {
		guard isRunning, generation == displayGeneration else { return }
		lastError = "macOS removed the virtual display"
		stop()
		start(loopback: loopback)
	}

	/// ScreenCaptureKit stops streams on its own — after sleep, a GPU reset, or a permission
	/// change. Restart it on the same display rather than tearing the whole session down.
	private func captureStopped(_ error: Error?) {
		guard isRunning, display != nil else { return }
		capturer = nil
		Task {
			try? await Task.sleep(for: .seconds(1))
			guard isRunning, capturer == nil else { return }
			do {
				try await startCapture()
			} catch {
				lastError = "Capture: \(error)"
				captureStopped(error)
			}
		}
	}

	/// Receives every change to the Thunderbolt Bridge from ``AppModel``, whether or not the
	/// session is running. Only a change of link or interface restarts discovery.
	func bridgeChanged(_ state: BridgeState?) {
		let previous = bridge
		bridge = state
		guard followsBridge, state?.needsRestart(from: previous) ?? true else { return }
		browseBridge()
	}

	/// Restarts discovery on the current bridge, or waits for a cable if it is not usable.
	private func browseBridge() {
		let state = bridge
		browser?.stop()
		browser = nil
		receivers = []
		guard let state, state.isUsable else {
			connectTask?.cancel()
			connectTask = nil
			link.setSender(nil)
			if isRunning { status = .waitingForCable }
			return
		}
		do {
			browser = try BonjourBrowser(interfaceIndex: state.index) { [weak self] names in
				self?.receivers = names
			}
			status = .searching
			startConnecting()
		} catch {
			status = .failed(String(describing: error))
		}
	}

	/// Keeps one connection up: picks a receiver, connects, and on failure waits and tries again.
	private func startConnecting() {
		connectTask?.cancel()
		connectTask = Task { [weak self] in
			while !Task.isCancelled {
				guard let self else { return }
				if let error = await self.connectOnce() {
					self.lastError = String(describing: error)
				}
				self.link.setSender(nil)
				guard !Task.isCancelled, self.isRunning else { return }
				if case .connected = self.status { self.status = .searching }
				try? await Task.sleep(for: .seconds(1))
			}
		}
	}

	/// Connects to the best receiver and returns when that connection ends.
	private func connectOnce() async -> Error? {
		let addresses: [SocketAddress]
		let name: String
		let interfaceIndex: UInt32
		var panel = receiverPanel
		if loopback {
			name = "this Mac"
			interfaceIndex = 0
			addresses = (try? SocketAddress.resolve(host: "127.0.0.1", port: Wire.port)) ?? []
		} else {
			guard let browser, let bridge, let target = preferredReceiver.flatMap({ receivers.contains($0) ? $0 : nil }) ?? receivers.first else {
				status = .searching
				return nil
			}
			name = target
			interfaceIndex = bridge.index
			status = .connecting(target)
			do {
				let service = try await browser.resolve(target)
				addresses = service.addresses
				// A receiver that publishes no geometry gets the last known size.
				panel = PanelGeometry(txtFields: service.txt) ?? receiverPanel
			} catch {
				return error
			}
		}

		if display?.panel != panel || display?.shape != shape {
			do {
				try await rebuildDisplay(for: panel)
			} catch {
				return error
			}
		}
		guard let display else { return nil }
		let size = display.currentPixelSize
		let hello = HelloMessage(width: UInt32(size.width), height: UInt32(size.height))
		let stream: TCPStream
		do {
			stream = try await Task.detached(priority: .userInitiated) {
				try Self.connectAndHandshake(addresses: addresses, interfaceIndex: interfaceIndex, hello: hello)
			}.value
		} catch {
			return error
		}

		let closed = AsyncStream<Error>.makeStream()
		let sender = FrameSender(stream: stream, width: size.width, height: size.height, stats: senderStats, settings: SharedSettings.current, onSettings: { [weak self] settings in
			Task { @MainActor in self?.settingsSync.receive(settings) }
		}) { error in
			closed.continuation.yield(error)
			closed.continuation.finish()
		}
		senderStats.resetRecent()
		history = []
		link.setSender(sender)
		status = .connected(name)
		lastError = nil
		Log.transport.info("Connected to \(name, privacy: .public) at \(stream.peerDescription, privacy: .public)")

		let error = await withTaskCancellationHandler {
			var iterator = closed.stream.makeAsyncIterator()
			return await iterator.next()
		} onCancel: {
			sender.stop()
		}
		sender.stop()
		Log.transport.info("Disconnected from \(name, privacy: .public): \(String(describing: error), privacy: .public)")
		return error
	}

	/// Tries each address in turn and performs the hello exchange on the first that answers.
	nonisolated private static func connectAndHandshake(addresses: [SocketAddress], interfaceIndex: UInt32, hello: HelloMessage) throws -> TCPStream {
		var lastError: Error = TransportError.unresolvable("receiver")
		for address in addresses {
			do {
				let stream = try TCPStream.connect(to: address, interfaceIndex: interfaceIndex)
				stream.setReadTimeout(3)
				try stream.writeHeader { hello.encode(into: $0) }
				_ = try stream.readHeader(HelloAckMessage.decode)
				stream.setReadTimeout(nil)
				return stream
			} catch {
				lastError = error
			}
		}
		throw lastError
	}

	private func startStatsTimer() {
		statsTimer?.invalidate()
		statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.stats = self.senderStats.drain()
				if case .connected = self.status {
					self.history.append(self.stats)
					self.history.removeFirst(max(0, self.history.count - LatencyBreakdown.historyLength))
				}
				if case .connected = self.status {
					self.recorder?.append(self.stats)
				}
			}
		}
	}

	private func updateRecorder() {
		if recordsStats, recorder == nil {
			do {
				recorder = try StatsRecorder()
				recordingURL = recorder?.url
			} catch {
				lastError = "Cannot record statistics: \(error.localizedDescription)"
				recordsStats = false
			}
		} else if !recordsStats {
			recorder = nil
		}
	}
}

/// Hands frames from the capture queue to whichever ``FrameSender`` is current, and keeps the
/// newest frame so a new connection starts with a full image even if the screen is static —
/// ScreenCaptureKit delivers nothing while the display is idle.
private final class CaptureLink: @unchecked Sendable {
	private let lock = NSLock()
	private var sender: FrameSender?
	private var latest: CapturedFrame?

	func deliver(_ frame: CapturedFrame) {
		let sender = lock.withLock {
			latest = frame
			return self.sender
		}
		sender?.submit(frame)
	}

	func setSender(_ newSender: FrameSender?) {
		let (old, latest) = lock.withLock {
			let old = sender
			sender = newSender
			return (old, self.latest)
		}
		if old !== newSender {
			old?.stop()
		}
		if let newSender, let latest {
			// The sender starts with the whole display marked dirty, so this goes out as a full frame.
			newSender.submit(CapturedFrame(sampleBuffer: latest.sampleBuffer, pixelBuffer: latest.pixelBuffer, dirtyRects: [], captureTime: latest.captureTime))
		}
	}

	func reset() {
		setSender(nil)
		lock.withLock { latest = nil }
	}

	/// Forwards a settings change to the receiver, if connected.
	func sendSettings(_ settings: SharedSettings) {
		lock.withLock { sender }?.sendSettings(settings)
	}
}
