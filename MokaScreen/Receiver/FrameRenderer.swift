// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Metal
import os
import QuartzCore

/// Errors setting up the GPU.
enum RendererError: Error, CustomStringConvertible {
	case noDevice
	case allocationFailed

	var description: String {
		switch self {
		case .noDevice: "No Metal device"
		case .allocationFailed: "Could not allocate display buffers"
		}
	}
}

/// Keeps the receiver's copy of the sender's display and draws it.
///
/// Received rectangles land in a ring of shared `MTLBuffer` slots. Each draw blits every frame
/// completed since the last draw — in order, because each one only patches the previous image —
/// into a private display texture, then draws that texture to the drawable. Only the newest state
/// is ever presented.
final class FrameRenderer: FrameSink {
	/// Slots in the receive ring: one being filled, one waiting to be drawn, one being blitted.
	static let slotCount = 3

	let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let pipeline: MTLRenderPipelineState
	private let nearestSampler: MTLSamplerState
	private let linearSampler: MTLSamplerState
	private let stats: ReceiverStats

	private let lock = NSLock()
	private var surface: Surface?
	private var pending: [ReceivedFrame] = []
	private var needsRedraw = true
	private var shuttingDown = false

	/// Called from a Metal thread with the newest frame ID and its glass time, in host
	/// nanoseconds, each time a drawable is presented.
	var onPresented: ((UInt64, UInt64) -> Void)?

	/// Called from the reader thread whenever there is something new to draw.
	var onWork: (() -> Void)? {
		get { lock.withLock { work } }
		set { lock.withLock { work = newValue } }
	}
	private var work: (() -> Void)?

	/// The display texture plus the slot ring that feeds it, for one display size.
	private final class Surface {
		let width: Int
		let height: Int
		let texture: MTLTexture
		let slots: [FrameSlot]
		var free: [FrameSlot]
		let available: DispatchSemaphore
		/// False until the first frame is blitted; the texture's initial contents are undefined.
		var hasContent = false

		init(device: MTLDevice, width: Int, height: Int) throws {
			self.width = width
			self.height = height
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
			descriptor.usage = [.shaderRead]
			descriptor.storageMode = .private
			guard let texture = device.makeTexture(descriptor: descriptor) else { throw RendererError.allocationFailed }
			self.texture = texture
			var slots: [FrameSlot] = []
			for _ in 0..<FrameRenderer.slotCount {
				guard let buffer = device.makeBuffer(length: width * height * 4, options: [.storageModeShared]) else {
					throw RendererError.allocationFailed
				}
				slots.append(FrameSlot(contents: buffer.contents(), capacity: buffer.length, owner: buffer))
			}
			self.slots = slots
			free = slots
			available = DispatchSemaphore(value: slots.count)
		}

		func owns(_ slot: FrameSlot) -> Bool {
			slots.contains { $0 === slot }
		}
	}

	init(stats: ReceiverStats) throws {
		guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
			throw RendererError.noDevice
		}
		self.device = device
		self.commandQueue = commandQueue
		self.stats = stats

		let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
		let descriptor = MTLRenderPipelineDescriptor()
		descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
		descriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
		descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
		pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

		let sampler = MTLSamplerDescriptor()
		sampler.sAddressMode = .clampToEdge
		sampler.tAddressMode = .clampToEdge
		sampler.minFilter = .nearest
		sampler.magFilter = .nearest
		nearestSampler = device.makeSamplerState(descriptor: sampler)!
		sampler.minFilter = .linear
		sampler.magFilter = .linear
		linearSampler = device.makeSamplerState(descriptor: sampler)!
	}

	// MARK: FrameSink (reader thread)

	func configure(width: Int, height: Int) throws {
		lock.lock()
		let reuse = surface.map { $0.width == width && $0.height == height } ?? false
		lock.unlock()
		guard !reuse else { return }
		let newSurface = try Surface(device: device, width: width, height: height)
		lock.lock()
		surface = newSurface
		pending.removeAll()
		needsRedraw = true
		shuttingDown = false
		let work = work
		lock.unlock()
		work?()
		Log.render.info("Display surface \(width, privacy: .public)×\(height, privacy: .public)")
	}

	func acquireSlot() -> FrameSlot? {
		lock.lock()
		let surface = surface
		lock.unlock()
		guard let surface else { return nil }
		// Waiting here is the receiver's backpressure: when the GPU falls behind, the socket stops
		// being read, TCP pushes back, and the sender's latest-frame-wins logic absorbs the delay.
		while surface.available.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
			if isShuttingDown { return nil }
		}
		lock.lock()
		defer { lock.unlock() }
		if shuttingDown {
			surface.available.signal()
			return nil
		}
		return surface.free.popLast()
	}

	func releaseUnused(_ slot: FrameSlot) {
		release([slot])
	}

	func commit(_ frame: ReceivedFrame) {
		lock.lock()
		pending.append(frame)
		let work = work
		lock.unlock()
		work?()
	}

	/// Unblocks a reader waiting for a slot; called when its connection ends.
	func shutDown() {
		lock.lock()
		shuttingDown = true
		lock.unlock()
	}

	private var isShuttingDown: Bool {
		lock.lock()
		defer { lock.unlock() }
		return shuttingDown
	}

	private func release(_ slots: [FrameSlot]) {
		lock.lock()
		defer { lock.unlock() }
		guard let surface else { return }
		for slot in slots where surface.owns(slot) {
			surface.free.append(slot)
			surface.available.signal()
		}
	}

	/// Draws again even if no frame arrived, e.g. after the drawable was resized.
	func setNeedsRedraw() {
		lock.lock()
		needsRedraw = true
		let work = work
		lock.unlock()
		work?()
	}

	/// Whether a frame or a redraw is waiting.
	var hasWork: Bool {
		lock.withLock { !pending.isEmpty || needsRedraw }
	}

	// MARK: Drawing (render thread)

	/// Applies every completed frame and draws the result, calling `whenShown` once the drawable
	/// has been presented or dropped. Returns false without presenting when nothing changed,
	/// which leaves the previous image on screen.
	func draw(to drawable: CAMetalDrawable, whenShown: @escaping () -> Void) -> Bool {
		lock.lock()
		let frames = pending
		pending.removeAll(keepingCapacity: true)
		let redraw = needsRedraw
		needsRedraw = false
		let surface = surface
		lock.unlock()

		guard let surface, !frames.isEmpty || redraw,
		      let commandBuffer = commandQueue.makeCommandBuffer()
		else {
			release(frames.map(\.slot))
			return false
		}

		let current = frames.filter { surface.owns($0.slot) }
		guard surface.hasContent || !current.isEmpty else {
			release(frames.map(\.slot))
			return false
		}
		surface.hasContent = true
		let receivedTimes = current.map(\.receivedTime)
		stats.recordDraw(receivedTimes: receivedTimes, at: HostClock.now)
		if !current.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
			for frame in current {
				let buffer = frame.slot.owner as! MTLBuffer
				for rect in frame.rects {
					blit.copy(
						from: buffer,
						sourceOffset: rect.offset,
						sourceBytesPerRow: rect.width * 4,
						sourceBytesPerImage: rect.width * 4 * rect.height,
						sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1),
						to: surface.texture,
						destinationSlice: 0,
						destinationLevel: 0,
						destinationOrigin: MTLOrigin(x: rect.x, y: rect.y, z: 0)
					)
				}
			}
			blit.endEncoding()
		}

		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store
		if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
			let fit = Self.fit(width: surface.width, height: surface.height, into: drawable.texture.width, drawable.texture.height)
			encoder.setViewport(fit.viewport)
			encoder.setRenderPipelineState(pipeline)
			encoder.setFragmentTexture(surface.texture, index: 0)
			encoder.setFragmentSamplerState(fit.isOneToOne ? nearestSampler : linearSampler, index: 0)
			encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			encoder.endEncoding()
		}

		let newest = current.last?.frameID
		let stats = stats
		let onPresented = onPresented
		drawable.addPresentedHandler { drawable in
			defer { whenShown() }
			let presented = drawable.presentedTime
			guard presented > 0, let newest else { return }
			let presentedNanos = UInt64(presented * 1e9)
			for received in receivedTimes {
				stats.recordPresented(delay: Double(presentedNanos &- received) / 1e9)
			}
			onPresented?(newest, presentedNanos)
		}
		commandBuffer.present(drawable)
		let slots = frames.map(\.slot)
		commandBuffer.addCompletedHandler { [weak self] _ in
			self?.release(slots)
		}
		commandBuffer.commit()
		return true
	}

	// Compiled at runtime (a few milliseconds, once per connection) so building MokaScreen needs
	// no Metal toolchain, which Xcode 26 and later ship as a separate download.
	private static let shaderSource = """
		#include <metal_stdlib>
		using namespace metal;

		struct VertexOut {
			float4 position [[position]];
			float2 uv;
		};

		// One triangle that covers the viewport; uv (0,0) is the texture's top-left.
		vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
			float2 p = float2((vid << 1) & 2, vid & 2);
			VertexOut out;
			out.position = float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
			out.uv = p;
			return out;
		}

		// At 1:1 the sampler is nearest, so each output pixel is exactly one received pixel.
		fragment float4 displayFragment(VertexOut in [[stage_in]],
		                                texture2d<float> display [[texture(0)]],
		                                sampler displaySampler [[sampler(0)]]) {
			return display.sample(displaySampler, in.uv);
		}
		"""

	/// Aspect-fits the frame into the drawable, horizontally centred and bottom-aligned so any
	/// spare height ends up behind the notch rather than split around the image.
	static func fit(width: Int, height: Int, into drawableWidth: Int, _ drawableHeight: Int) -> (viewport: MTLViewport, isOneToOne: Bool) {
		let scale = min(Double(drawableWidth) / Double(width), Double(drawableHeight) / Double(height))
		let isOneToOne = abs(scale - 1) < 0.001
		let w = isOneToOne ? Double(width) : (Double(width) * scale).rounded()
		let h = isOneToOne ? Double(height) : (Double(height) * scale).rounded()
		let x = ((Double(drawableWidth) - w) / 2).rounded(.down)
		let y = Double(drawableHeight) - h
		return (MTLViewport(originX: x, originY: y, width: w, height: h, znear: 0, zfar: 1), isOneToOne)
	}
}
