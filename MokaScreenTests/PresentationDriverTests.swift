// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import QuartzCore
import Testing
@testable import MokaScreen

@Suite struct PresentationDriverTests {
	/// A paused display Mac must keep freeing slots, or the reader blocks and the sender stalls.
	@Test func pausedDriverKeepsTakingFrames() throws {
		let size = 64
		let renderer = try FrameRenderer(stats: ReceiverStats())
		try renderer.configure(width: size, height: size)
		let layer = CAMetalLayer()
		layer.device = renderer.device
		layer.pixelFormat = .bgra8Unorm
		layer.drawableSize = CGSize(width: size, height: size)
		let driver = PresentationDriver(layer: layer, renderer: renderer)
		driver.setPaused(true)
		driver.start()
		defer { driver.stop() }

		let frameCount = FrameRenderer.slotCount * 10
		let done = DispatchSemaphore(value: 0)
		let delivered = Delivered()
		let reader = Thread {
			for id in 1...frameCount {
				guard let slot = renderer.acquireSlot() else { break }
				let rect = ReceivedRect(x: 0, y: 0, width: size, height: size, offset: 0)
				renderer.commit(ReceivedFrame(frameID: UInt64(id), rects: [rect], slot: slot, receivedTime: HostClock.now))
				delivered.count = id
			}
			done.signal()
		}
		reader.start()

		let finished = done.wait(timeout: .now() + 5) == .success
		if !finished {
			renderer.shutDown()
			done.wait()
		}
		#expect(finished)
		#expect(delivered.count == frameCount)
	}
}

private final class Delivered: @unchecked Sendable {
	var count = 0
}
