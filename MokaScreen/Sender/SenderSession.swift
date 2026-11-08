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
	private(set) var bridge: BridgeState?
	private(set) var receivers: [String] = []
	private(set) var displayDescription = "—"
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

	/// Write one CSV row per second of activity to `~/Library/Logs/MokaScreen`.
	var recordsStats = false {
		didSet { updateRecorder() }
	}

	@ObservationIgnored private var display: VirtualDisplay?
	@ObservationIgnored private var capturer: ScreenCapturer?
	@ObservationIgnored private var monitor: BridgeMonitor?
	@ObservationIgnored private var browser: BonjourBrowser?
	@ObservationIgnored private var connectTask: Task<Void, Never>?
	@ObservationIgnored private var statsTimer: Timer?
	@ObservationIgnored private var recorder: StatsRecorder?
	@ObservationIgnored private var loopback = false
	@ObservationIgnored private let senderStats = SenderStats()
	@ObservationIgnored private let link = CaptureLink()

	init() {
		shape = UserDefaults.standard.string(forKey: "displayShape").flatMap(DisplayShape.init) ?? .fullPanel
		preferredReceiver = UserDefaults.standard.string(forKey: "preferredReceiver")
	}

	var isRunning: Bool { status != .stopped }

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
				startMonitoringBridge()
			}
		}
	}

	private func startMonitoringBridge() {
		monitor = BridgeMonitor { [weak self] state in
			self?.bridgeChanged(state)
		}
	}

	/// Disconnects and removes the virtual display.
	func stop() {
		connectTask?.cancel()
		connectTask = nil
		link.setSender(nil)
		monitor?.stop()
		monitor = nil
		browser?.stop()
		browser = nil
		receivers = []
		statsTimer?.invalidate()
		statsTimer = nil
		teardownDisplay()
		status = .stopped
	}

	private func startDisplayAndCapture() async throws {
		let display = try VirtualDisplay(shape: shape) { [weak self] in
			Task { @MainActor in self?.displayTerminated() }
		}
		self.display = display
		try await display.activate()
		displayDescription = display.currentModeDescription
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
		displayDescription = "—"
	}

	private func displayTerminated() {
		guard isRunning else { return }
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

	private func bridgeChanged(_ state: BridgeState?) {
		let previous = bridge
		bridge = state
		// The first call always restarts; afterwards only link changes do.
		guard browser == nil || state?.needsRestart(from: previous) ?? true else { return }
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
				addresses = try await browser.resolve(target)
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
		let sender = FrameSender(stream: stream, width: size.width, height: size.height, stats: senderStats) { error in
			closed.continuation.yield(error)
			closed.continuation.finish()
		}
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
}
