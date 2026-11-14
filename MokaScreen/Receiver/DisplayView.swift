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
import os
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
	/// How long after it was drawn a drawable presented at once may go unreported before it stops
	/// counting as in flight. After the picture has been still for about a second, macOS 27.2 never
	/// calls the presented handler for the first one or two drawables presented, though later ones
	/// report normally (measured 2026-11-14 on a ProMotion MacBook Pro whose display link kept
	/// ticking at 120 Hz throughout). Waiting a flat 100 ms for those reports stalled drawing for
	/// up to that long whenever motion resumed. A drawable presented at once reaches the glass
	/// within about two refreshes.
	static let reportGraceRefreshes = 2.0
	/// How long the picture may stay unchanged before the unchanged image is presented again, and
	/// how often while it stays so. On the same ProMotion MacBook Pro, presenting the unchanged
	/// image every 250 ms during stills of 1–2 s left no presented report missing afterwards,
	/// against 16 lost over 9 stills without it; the keep-alive presents themselves always
	/// reported. Four full-screen redraws a second while nothing changes cost a fraction of a
	/// millisecond of GPU time each.
	static let keepAliveInterval: TimeInterval = 0.25
	/// The same for a drawable Smooth Motion presented at a chosen time, counted from that time.
	/// Its report arrives about a millisecond after it, so one refresh never cuts one short. With
	/// two, the drawables whose reports were lost kept the next ones waiting: a recording on
	/// 2026-11-14 showed frames reaching the glass 1.5 refreshes late for 90 ms after a still
	/// moment before they settled.
	static let pacedReportGraceRefreshes = 1.0

	private let layer: CAMetalLayer
	private let renderer: FrameRenderer
	private let wake = DispatchSemaphore(value: 0)
	/// Guards `stopped`, `paused`, and `inFlight`, and signals when a drawable is presented.
	private let condition = NSCondition()
	private var stopped = false
	private var paused = false
	private var inFlight = InFlightDrawables()
	private var nextToken: UInt64 = 0

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
		// Set when nothing has arrived for ``keepAliveInterval``.
		var keepAliveDue = false
		while true {
			if let recheck {
				let now = HostClock.now
				if recheck > now {
					_ = wake.wait(timeout: .now() + .nanoseconds(Int(recheck - now)))
				}
			} else if wake.wait(timeout: .now() + Self.keepAliveInterval) == .timedOut {
				keepAliveDue = true
			}
			let (isStopped, isPaused) = condition.withLock { (stopped, paused) }
			if isStopped { return }
			if isPaused {
				recheck = nil
				keepAliveDue = false
				renderer.absorb()
				continue
			}
			guard waitForRoom() else { return }
			if keepAliveDue {
				keepAliveDue = false
				renderer.keepAlive()
			}
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
			let refresh = renderer.refreshInterval * 1e9
			let grace = UInt64(refresh * Self.reportGraceRefreshes)
			let pacedGrace = UInt64(refresh * Self.pacedReportGraceRefreshes)
			// Counted before drawing, as the presented handler can run before draw returns; the
			// deadline is set from the glass time once draw has chosen it.
			let token = condition.withLock {
				nextToken &+= 1
				inFlight.add(token: nextToken, deadline: HostClock.now &+ UInt64(FramePacer.maximumDelayNanos) &+ grace)
				return nextToken
			}
			if let glass = renderer.draw(to: drawable, whenShown: { [weak self] in self?.presented(token) }) {
				let deadline = glass > 0 ? glass &+ pacedGrace : HostClock.now &+ grace
				condition.withLock { inFlight.setDeadline(deadline, for: token) }
			} else {
				presented(token)
			}
		}
	}

	/// Waits until fewer than ``maxInFlight`` (or ``maxInFlightPaced``) drawables are in flight,
	/// counting one whose report is overdue as no longer in flight. Returns false once stopped.
	private func waitForRoom() -> Bool {
		let limit = renderer.smoothMotion ? Self.maxInFlightPaced : Self.maxInFlight
		return condition.withLock {
			while !stopped {
				let now = HostClock.now
				let lost = inFlight.expire(now: now)
				if lost > 0 {
					Log.render.debug("\(lost, privacy: .public) drawable(s) never reported presented; drawing on")
				}
				guard inFlight.count >= limit, let next = inFlight.earliestDeadline else { return true }
				condition.wait(until: Date(timeIntervalSinceNow: Double(next &- now) / 1e9))
			}
			return false
		}
	}

	private func presented(_ token: UInt64) {
		condition.withLock {
			if inFlight.complete(token: token) {
				condition.signal()
			}
		}
	}
}

/// The drawables presented but not yet reported, each with the host time after which it no longer
/// counts as in flight. Holds at most a few entries; used under ``PresentationDriver``'s lock.
struct InFlightDrawables {
	private var entries: [(token: UInt64, deadline: UInt64)] = []

	init() {
		entries.reserveCapacity(8)
	}

	var count: Int { entries.count }

	var earliestDeadline: UInt64? {
		var earliest: UInt64?
		for entry in entries where entry.deadline < earliest ?? .max {
			earliest = entry.deadline
		}
		return earliest
	}

	mutating func add(token: UInt64, deadline: UInt64) {
		entries.append((token, deadline))
	}

	mutating func setDeadline(_ deadline: UInt64, for token: UInt64) {
		if let index = entries.firstIndex(where: { $0.token == token }) {
			entries[index].deadline = deadline
		}
	}

	/// Removes a drawable that reported; false if it had already expired or never counted.
	mutating func complete(token: UInt64) -> Bool {
		guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }
		entries.remove(at: index)
		return true
	}

	/// Removes every drawable past its deadline and returns how many there were.
	mutating func expire(now: UInt64) -> Int {
		let before = entries.count
		entries.removeAll { $0.deadline <= now }
		return before - entries.count
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
