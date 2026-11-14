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
	/// Slots in the receive ring: one being filled, one being blitted, and the rest for frames
	/// waiting to be drawn. Smooth Motion holds a frame here until a refresh before its glass
	/// time, up to ``FramePacer/maximumDelayNanos`` (30 ms) after it arrives: about four frames
	/// at 120 Hz. When every slot is full the reader stops reading and the sender drops frames,
	/// so two are spare. Each slot holds a full frame, about 31 MB.
	static let slotCount = 8

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
	/// A redraw of the unchanged picture asked for by ``keepAlive()``, left out of the statistics.
	private var needsKeepAlive = false
	private var shuttingDown = false
	private var pacesFrames = false
	private var pacingFloorNanos: Int64 = 0
	/// Host nanoseconds until which each draw reports its frames through `onFrameTiming`.
	private var timingUntil: UInt64 = 0
	/// Render thread only.
	private var pacer = FramePacer()
	/// The newest frame whose trip the pacer has recorded. Render thread only.
	private var pacedThrough: UInt64 = 0

	/// Whether frames are presented at their paced glass time rather than as soon as they are
	/// drawn. Thread-safe; takes effect from the next draw.
	var smoothMotion: Bool {
		get { lock.withLock { pacesFrames } }
		set { lock.withLock { pacesFrames = newValue } }
	}

	/// The least delay Smooth Motion schedules with, in milliseconds; 0 for adaptive. Thread-safe;
	/// takes effect from the next draw.
	var smoothMotionFloorMillis: Int {
		get { lock.withLock { Int(pacingFloorNanos / 1_000_000) } }
		set { lock.withLock { pacingFloorNanos = Int64(max(0, newValue)) * 1_000_000 } }
	}

	/// The panel's refresh interval in seconds, for judging whether frames reach the glass evenly.
	var refreshInterval: Double = 1.0 / 120

	/// The panel's refreshes, so Smooth Motion presents on one. Set before the first frame arrives.
	var displayTicks: DisplayTicks?

	/// Called from a Metal thread with the newest frame ID and its glass time, in host
	/// nanoseconds, each time a drawable is presented.
	var onPresented: ((UInt64, UInt64) -> Void)?

	/// Called from a Metal thread once per frame drawn while timing is being recorded. Set before
	/// the first frame arrives.
	var onFrameTiming: ((FrameTimingMessage) -> Void)?

	/// Reports every frame drawn for the next `seconds` through ``onFrameTiming``. Thread-safe.
	func recordTiming(for seconds: Double) {
		lock.withLock { timingUntil = HostClock.now &+ UInt64(seconds * 1e9) }
	}

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

	// MARK: Drawing (render thread)

	/// When the next draw is due, in host nanoseconds; nil when nothing is waiting.
	///
	/// Without Smooth Motion every frame is due on arrival. With it, a frame is due one refresh
	/// before its paced glass time, so it waits in its receive slot rather than in a drawable:
	/// macOS gives a layer at most three drawables, fewer than the frames that can be waiting
	/// under a delay of up to 30 ms.
	func nextDrawTime() -> UInt64? {
		lock.lock()
		defer { lock.unlock() }
		recordTrips()
		if needsRedraw || needsKeepAlive { return 0 }
		guard let oldest = pending.first else { return nil }
		guard pacesFrames else { return 0 }
		return drawTime(of: oldest)
	}

	/// Asks for the unchanged picture to be presented again. See
	/// ``PresentationDriver/keepAliveInterval``. Render thread only.
	func keepAlive() {
		lock.withLock { needsKeepAlive = true }
	}

	/// Records the trip of every frame that has arrived since the last call, and applies the
	/// current minimum delay. Caller holds `lock`.
	private func recordTrips() {
		pacer.floorNanos = pacingFloorNanos
		for frame in pending where frame.frameID > pacedThrough {
			pacer.record(captureTime: frame.captureTime, receivedTime: frame.receivedTime)
			pacedThrough = frame.frameID
		}
	}

	/// When a waiting frame should be drawn under Smooth Motion: a refresh before its glass time,
	/// and never more than the pacer's cap after it arrived, in case the clock estimate is off.
	private func drawTime(of frame: ReceivedFrame) -> UInt64 {
		guard let glass = presentTime(of: frame) else { return 0 }
		let lead = UInt64(refreshInterval * 1e9)
		let latest = frame.receivedTime &+ UInt64(FramePacer.maximumDelayNanos)
		return min(glass > lead ? glass - lead : 0, latest)
	}

	/// The time to pass to `present(_:atTime:)` for a frame under Smooth Motion: its paced glass
	/// time moved forward to the panel's next refresh, less a millisecond so the panel shows it on
	/// that refresh rather than the half-step after. Without known refreshes, the paced glass time.
	private func presentTime(of frame: ReceivedFrame) -> UInt64? {
		guard let glass = pacer.glassTime(captureTime: frame.captureTime) else { return nil }
		guard let tick = displayTicks?.tick(atOrAfter: glass) else { return glass }
		return tick &- 1_000_000
	}

	/// Applies every frame that is due (see ``nextDrawTime()``) and draws the result, calling
	/// `whenShown` once the drawable has been presented or dropped. Returns the host time the
	/// drawable was asked to reach the glass, or 0 for as soon as possible; nil without presenting
	/// when nothing changed, which leaves the previous image on screen.
	func draw(to drawable: CAMetalDrawable, whenShown: @escaping () -> Void) -> UInt64? {
		lock.lock()
		recordTrips()
		let frames: [ReceivedFrame]
		if pacesFrames {
			// Frames due within half a millisecond are drawn now rather than a wake-up later.
			let horizon = HostClock.now &+ 500_000
			let due = pending.prefix { drawTime(of: $0) <= horizon }.count
			frames = Array(pending.prefix(due))
			pending.removeFirst(due)
		} else {
			frames = pending
			pending.removeAll(keepingCapacity: true)
		}
		let keepAlive = needsKeepAlive && frames.isEmpty && !needsRedraw
		let redraw = needsRedraw || needsKeepAlive
		needsRedraw = false
		needsKeepAlive = false
		let surface = surface
		let pacesFrames = pacesFrames
		let recordsTiming = timingUntil > HostClock.now
		lock.unlock()

		guard let surface, !frames.isEmpty || redraw,
		      let commandBuffer = commandQueue.makeCommandBuffer()
		else {
			release(frames.map(\.slot))
			return nil
		}

		let current = frames.filter { surface.owns($0.slot) }
		guard surface.hasContent || !current.isEmpty else {
			release(frames.map(\.slot))
			return nil
		}
		surface.hasContent = true
		let receivedTimes = current.map(\.receivedTime)
		// A keep-alive is not a frame: counting it would show draws while nothing changes.
		if !keepAlive {
			stats.recordDraw(receivedTimes: receivedTimes, at: HostClock.now)
		}
		stats.recordPacing(milliseconds: pacesFrames ? Double(pacer.effectiveDelay) / 1e6 : 0)
		encodeBlit(current, to: surface, in: commandBuffer)

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

		let newest = current.last
		let stats = stats
		let onPresented = onPresented
		let refreshNanos = UInt64(refreshInterval * 1e9)
		// Smooth Motion holds a frame until its paced glass time; one already due goes at once.
		var pacedGlass: UInt64?
		if pacesFrames, let newest, let glass = presentTime(of: newest), glass > HostClock.now &+ 1_000_000 {
			pacedGlass = glass
		}
		var timing: [FrameTimingMessage] = []
		if recordsTiming, onFrameTiming != nil, !current.isEmpty {
			let drawTime = HostClock.now
			let target = pacedGlass.map { UInt16(clamping: ($0 &- drawTime) / 100_000) } ?? 0
			timing = current.map {
				FrameTimingMessage(frameID: $0.frameID, drawTime: drawTime, receivedBeforeDrawMicros: UInt32(clamping: (drawTime &- $0.receivedTime) / 1000), glassAfterDrawMicros: -1, drawnTogether: UInt16(clamping: current.count), paced: pacedGlass != nil, targetAfterDrawTenths: target)
			}
		}
		let onFrameTiming = onFrameTiming
		drawable.addPresentedHandler { drawable in
			defer { whenShown() }
			let presented = drawable.presentedTime
			if !timing.isEmpty, let onFrameTiming {
				let presentedNanos = presented > 0 ? UInt64(presented * 1e9) : 0
				for var frame in timing {
					if presentedNanos > 0 {
						frame.glassAfterDrawMicros = Int32(clamping: (Int64(bitPattern: presentedNanos) - Int64(bitPattern: frame.drawTime)) / 1000)
					}
					onFrameTiming(frame)
				}
			}
			guard presented > 0, let newest else { return }
			let presentedNanos = UInt64(presented * 1e9)
			for received in receivedTimes {
				stats.recordPresented(delay: Double(presentedNanos &- received) / 1e9)
			}
			stats.recordGlass(captureTime: newest.captureTime, glassTime: presentedNanos, refreshNanos: refreshNanos)
			onPresented?(newest.frameID, presentedNanos)
		}
		if let glass = pacedGlass {
			commandBuffer.present(drawable, atTime: Double(glass) / 1e9)
		} else {
			commandBuffer.present(drawable)
		}
		let slots = frames.map(\.slot)
		commandBuffer.addCompletedHandler { [weak self] _ in
			self?.release(slots)
		}
		commandBuffer.commit()
		return pacedGlass ?? 0
	}

	/// Applies every completed frame to the display texture without presenting anything.
	///
	/// While the display Mac is paused, frames must still be taken off the wire: otherwise the
	/// slots stay full, the socket stops being read, and the sender's writes block. Applying
	/// them keeps the texture current, so resuming shows the newest image at once.
	func absorb() {
		lock.lock()
		let frames = pending
		pending.removeAll(keepingCapacity: true)
		let surface = surface
		lock.unlock()

		let slots = frames.map(\.slot)
		guard let surface else {
			release(slots)
			return
		}
		let current = frames.filter { surface.owns($0.slot) }
		guard !current.isEmpty, let commandBuffer = commandQueue.makeCommandBuffer() else {
			release(slots)
			return
		}
		surface.hasContent = true
		encodeBlit(current, to: surface, in: commandBuffer)
		commandBuffer.addCompletedHandler { [weak self] _ in
			self?.release(slots)
		}
		commandBuffer.commit()
	}

	private func encodeBlit(_ frames: [ReceivedFrame], to surface: Surface, in commandBuffer: MTLCommandBuffer) {
		guard !frames.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
		for frame in frames {
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
