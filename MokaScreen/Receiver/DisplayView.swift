// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import Metal
import QuartzCore
import Synchronization

/// A view backed by a `CAMetalLayer` whose drawable always matches the view's pixel size.
final class MetalLayerView: NSView {
	let metalLayer = CAMetalLayer()
	var onDrawableResize: (() -> Void)?

	init(device: MTLDevice) {
		super.init(frame: .zero)
		metalLayer.device = device
		metalLayer.pixelFormat = .bgra8Unorm
		// Pixels arrive in Display P3 (see ScreenCapturer); tagging the layer makes the compositor
		// map them to the panel exactly as the sender's WindowServer intended.
		metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
		metalLayer.isOpaque = true
		metalLayer.framebufferOnly = true
		metalLayer.backgroundColor = .black
		// Hosting the layer (assigning it before wantsLayer) keeps AppKit from replacing it.
		layer = metalLayer
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError()
	}

	override func layout() {
		super.layout()
		updateDrawableSize()
	}

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		updateDrawableSize()
	}

	private func updateDrawableSize() {
		let scale = window?.backingScaleFactor ?? 2
		metalLayer.contentsScale = scale
		let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
		if size.width > 0, size.height > 0, size != metalLayer.drawableSize {
			metalLayer.drawableSize = size
			onDrawableResize?()
		}
	}
}

/// Draws each frame as soon as it has arrived, on a dedicated thread.
///
/// A `CAMetalDisplayLink` with `preferredFrameLatency = 1` put about one more refresh between a
/// frame's arrival and the glass than expected: at a steady 100+ fps the display Mac's share
/// measured 20 ms against 12.5 ms for an average half-refresh wait plus one refresh. Presenting on
/// arrival removes the wait for the tick and lets ProMotion refresh the panel as soon as the frame
/// is ready.
///
/// Up to two drawables are in flight, three under Smooth Motion; frames that arrive while the
/// limit is reached are folded into the next draw instead of queuing behind them. Under Smooth
/// Motion a frame waits in its receive slot until the renderer says it is due, a refresh before
/// its paced glass time, so the thread sleeps until then rather than drawing on arrival.
/// Presenting on arrival does not by itself tell macOS what refresh rate the screen needs;
/// ``RefreshRateRequest`` does.
final class PresentationDriver {
	static let maxInFlight = 2
	static let maxInFlightPaced = 3
	/// How long to wait for a drawable to be reported presented before drawing anyway, so a report
	/// that never comes cannot freeze the screen.
	private static let presentTimeout: TimeInterval = 0.1

	private let layer: CAMetalLayer
	private let renderer: FrameRenderer
	private let wake = DispatchSemaphore(value: 0)
	/// Guards `stopped`, `inFlight`, and `epoch`, and signals when a drawable is presented.
	private let condition = NSCondition()
	private var stopped = false
	private var paused = false
	private var inFlight = 0
	/// Advances when a timeout clears `inFlight`, so reports for drawables from before it are ignored.
	private var epoch = 0

	init(layer: CAMetalLayer, renderer: FrameRenderer) {
		self.layer = layer
		self.renderer = renderer
	}

	func start() {
		renderer.onWork = { [wake] in wake.signal() }
		let thread = Thread { [self] in run() }
		thread.name = "MokaScreen.render"
		thread.qualityOfService = .userInteractive
		thread.start()
		// Frames that arrived before the window was shown are already waiting.
		wake.signal()
	}

	func stop() {
		renderer.onWork = nil
		condition.withLock {
			stopped = true
			condition.broadcast()
		}
		wake.signal()
	}

	/// While paused, arriving frames are applied to the image but not presented; resuming
	/// presents the newest image at once.
	func setPaused(_ isPaused: Bool) {
		condition.withLock { paused = isPaused }
		if isPaused {
			wake.signal()
		} else {
			renderer.setNeedsRedraw()
		}
	}

	private func run() {
		// When to look again without a wake-up: nil to sleep until a frame arrives, or the host time
		// a waiting frame becomes due.
		var recheck: UInt64?
		while true {
			if let recheck {
				let now = HostClock.now
				if recheck > now {
					_ = wake.wait(timeout: .now() + .nanoseconds(Int(recheck - now)))
				}
			} else {
				wake.wait()
			}
			let (isStopped, isPaused) = condition.withLock { (stopped, paused) }
			if isStopped { return }
			if isPaused {
				recheck = nil
				renderer.absorb()
				continue
			}
			guard waitForRoom() else { return }
			guard let due = renderer.nextDrawTime() else {
				recheck = nil
				continue
			}
			if due > HostClock.now &+ 500_000 {
				recheck = due
				continue
			}
			// More frames may be waiting behind this one; look again straight after drawing.
			recheck = 0
			guard let drawable = layer.nextDrawable() else { continue }
			let current = condition.withLock {
				inFlight += 1
				return epoch
			}
			let presented = renderer.draw(to: drawable) { [weak self] in self?.presented(current) }
			if !presented {
				self.presented(current)
			}
		}
	}

	/// Waits until fewer than ``maxInFlight`` (or ``maxInFlightPaced``) drawables are in flight,
	/// or the timeout passes. Returns false once stopped.
	private func waitForRoom() -> Bool {
		let limit = renderer.smoothMotion ? Self.maxInFlightPaced : Self.maxInFlight
		return condition.withLock {
			let deadline = Date(timeIntervalSinceNow: Self.presentTimeout)
			while inFlight >= limit, !stopped {
				if !condition.wait(until: deadline) {
					inFlight = 0
					epoch &+= 1
				}
			}
			return !stopped
		}
	}

	private func presented(_ drawableEpoch: Int) {
		condition.withLock {
			guard drawableEpoch == epoch, inFlight > 0 else { return }
			inFlight -= 1
			condition.signal()
		}
	}
}

/// Asks macOS to run the screen showing `view` at 120 Hz for as long as the request exists.
///
/// With frames presented on arrival and no display link, macOS sometimes ran the display Mac's
/// ProMotion panel at 60 Hz under a steady 110 fps load: draws fell to 60 a second, frames waited
/// about 8 ms to be folded in pairs, and each then took a 16.7 ms refresh to reach the glass, for
/// about 23 ms instead of about 7. A display link's frame-rate range is the rate request macOS
/// takes from an app; its callback only notes when the panel refreshed, in `ticks`.
final class RefreshRateRequest: NSObject {
	private var link: CADisplayLink?
	private let ticks: DisplayTicks?

	init(view: NSView, ticks: DisplayTicks? = nil) {
		self.ticks = ticks
		super.init()
		let link = view.displayLink(target: self, selector: #selector(tick))
		link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
		link.add(to: .main, forMode: .common)
		self.link = link
	}

	@objc private func tick(_ link: CADisplayLink) {
		ticks?.record(timestamp: link.timestamp, duration: link.duration)
	}

	/// Ends the request. The link retains its target, so this also breaks that cycle.
	func invalidate() {
		link?.invalidate()
		link = nil
	}
}

/// When the panel last refreshed and how often, so Smooth Motion can present on a refresh.
///
/// A ProMotion panel held at 120 Hz still steps in 4.17 ms (NSScreen.displayUpdateGranularity),
/// so a frame presented between two refreshes can reach the glass on a half-step. A frame timing
/// recording on 2026-11-14 showed 23 of 715 paced frames 4.17 ms off their capture spacing.
/// Written on the main thread by ``RefreshRateRequest``; read on the render thread.
final class DisplayTicks: Sendable {
	private let last = Atomic<UInt64>(0)
	private let interval = Atomic<UInt64>(0)
	/// Ticks older than this are not trusted, e.g. once Fixed 120 Hz is turned off.
	static let staleAfterNanos: UInt64 = 1_000_000_000

	/// Notes a refresh at `timestamp`, in host seconds, of a panel refreshing every `duration`.
	func record(timestamp: CFTimeInterval, duration: CFTimeInterval) {
		guard timestamp > 0, duration > 0 else { return }
		interval.store(UInt64(duration * 1e9), ordering: .relaxed)
		last.store(UInt64(timestamp * 1e9), ordering: .releasing)
	}

	/// The first refresh at or after `time`, in host nanoseconds; nil while no recent refresh is
	/// known.
	func tick(atOrAfter time: UInt64, now: UInt64 = HostClock.now) -> UInt64? {
		let last = last.load(ordering: .acquiring)
		let interval = interval.load(ordering: .relaxed)
		guard last > 0, interval > 0, now &- last < Self.staleAfterNanos || last > now else { return nil }
		guard time > last else { return last }
		let steps = (time - last + interval - 1) / interval
		return last + steps * interval
	}
}

/// A borderless window that covers a whole screen, including the area beside the notch.
final class FullScreenWindow: NSWindow {
	var onExit: (() -> Void)?

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }

	override func cancelOperation(_ sender: Any?) {
		onExit?()
	}
}
