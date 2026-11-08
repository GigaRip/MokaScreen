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

/// Drives a ``FrameRenderer`` from a `CAMetalDisplayLink` on a dedicated thread.
///
/// `CAMetalDisplayLink` (rather than a plain `CADisplayLink`) hands over a drawable already
/// timed for the next refresh, and `preferredFrameLatency = 1` asks for it to be shown on the
/// very next vsync. Running on its own thread keeps presentation independent of the main
/// thread, so UI work on the receiver cannot cost a frame.
final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate {
	private let layer: CAMetalLayer
	private let renderer: FrameRenderer
	private let lock = NSLock()
	private var link: CAMetalDisplayLink?
	private var runLoop: CFRunLoop?
	private var stopped = false

	init(layer: CAMetalLayer, renderer: FrameRenderer) {
		self.layer = layer
		self.renderer = renderer
	}

	func start() {
		let thread = Thread { [self] in
			let link = CAMetalDisplayLink(metalLayer: layer)
			link.delegate = self
			link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
			link.preferredFrameLatency = 1
			link.add(to: .current, forMode: .default)
			lock.withLock {
				self.link = link
				runLoop = CFRunLoopGetCurrent()
			}
			while !lock.withLock({ stopped }) {
				RunLoop.current.run(mode: .default, before: .distantFuture)
			}
			link.invalidate()
		}
		thread.name = "MokaScreen.render"
		thread.qualityOfService = .userInteractive
		thread.start()
	}

	func stop() {
		lock.withLock {
			stopped = true
			if let runLoop {
				CFRunLoopStop(runLoop)
			}
		}
	}

	func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
		renderer.draw(to: update.drawable)
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
