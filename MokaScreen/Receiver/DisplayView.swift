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
/// Up to two drawables are in flight; frames that arrive while both are in flight are folded
/// into the next draw instead of queuing behind them. Presenting on arrival does not by itself
/// tell macOS what refresh rate the screen needs; ``RefreshRateRequest`` does.
final class PresentationDriver {
	static let maxInFlight = 2
	/// How long to wait for a drawable to be reported presented before drawing anyway, so a report
	/// that never comes cannot freeze the screen.
	private static let presentTimeout: TimeInterval = 0.1

	private let layer: CAMetalLayer
	private let renderer: FrameRenderer
	private let wake = DispatchSemaphore(value: 0)
	/// Guards `stopped`, `inFlight`, and `epoch`, and signals when a drawable is presented.
	private let condition = NSCondition()
	private var stopped = false
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

	private func run() {
		while true {
			wake.wait()
			guard waitForRoom() else { return }
			guard renderer.hasWork, let drawable = layer.nextDrawable() else { continue }
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

	/// Waits until fewer than ``maxInFlight`` drawables are in flight, or the timeout passes.
	/// Returns false once stopped.
	private func waitForRoom() -> Bool {
		condition.withLock {
			let deadline = Date(timeIntervalSinceNow: Self.presentTimeout)
			while inFlight >= Self.maxInFlight, !stopped {
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
/// takes from an app; this link's callback does nothing.
final class RefreshRateRequest: NSObject {
	private var link: CADisplayLink?

	init(view: NSView) {
		super.init()
		let link = view.displayLink(target: self, selector: #selector(tick))
		link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
		link.add(to: .main, forMode: .common)
		self.link = link
	}

	@objc private func tick(_ link: CADisplayLink) {}

	/// Ends the request. The link retains its target, so this also breaks that cycle.
	func invalidate() {
		link?.invalidate()
		link = nil
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
