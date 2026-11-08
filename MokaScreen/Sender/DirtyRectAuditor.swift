// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreVideo
import Foundation
import os

/// Checks ScreenCaptureKit's dirty rectangles against what actually changed.
///
/// The sender trusts `SCStreamFrameInfo.dirtyRects` to say which pixels to send. Apple does not
/// document their coordinate space, and a rectangle reported in points rather than pixels would
/// leave three quarters of each update unsent. The auditor keeps a copy of the previous frame,
/// diffs every tile, and logs once per second how many changed tiles the reported rectangles
/// missed. Enable with `defaults write com.gigarip.mokascreen AuditDirtyRects -bool YES`; it
/// costs a full-frame compare and copy per frame, so it is off by default.
final class DirtyRectAuditor {
	static var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: "AuditDirtyRects")
	}

	private var previous: UnsafeMutableRawPointer?
	private var width = 0
	private var height = 0
	private var frames = 0
	private var changedTiles = 0
	private var missedTiles = 0
	private var lastReport = Date()

	deinit {
		previous?.deallocate()
	}

	/// Compares `frame` with the previous one. Called on the capture queue.
	func audit(_ frame: CapturedFrame) {
		let pixelBuffer = frame.pixelBuffer
		CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
		let w = CVPixelBufferGetWidth(pixelBuffer)
		let h = CVPixelBufferGetHeight(pixelBuffer)
		let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
		let rowBytes = w * 4

		if previous == nil || w != width || h != height {
			previous?.deallocate()
			previous = .allocate(byteCount: rowBytes * h, alignment: 64)
			width = w
			height = h
			copy(from: base, bytesPerRow: bytesPerRow)
			return
		}
		guard let previous else { return }

		var reported = DirtyRegion(width: w, height: h)
		frame.dirtyRects.forEach { reported.insert($0) }
		let tile = reported.tileSize
		for row in 0..<reported.rows {
			for column in 0..<reported.columns {
				let x = column * tile
				let y = row * tile
				let tileWidth = min(tile, w - x) * 4
				var changed = false
				for line in y..<min(y + tile, h) where !changed {
					changed = memcmp(base + line * bytesPerRow + x * 4, previous + line * rowBytes + x * 4, tileWidth) != 0
				}
				if changed {
					changedTiles += 1
					if !reported.containsTile(column: column, row: row) { missedTiles += 1 }
				}
			}
		}
		copy(from: base, bytesPerRow: bytesPerRow)
		frames += 1

		if Date().timeIntervalSince(lastReport) >= 1 {
			let level: OSLogType = missedTiles > 0 ? .error : .info
			Log.capture.log(level: level, "Dirty-rect audit: \(self.frames, privacy: .public) frames, \(self.changedTiles, privacy: .public) changed tiles, \(self.missedTiles, privacy: .public) not reported")
			frames = 0
			changedTiles = 0
			missedTiles = 0
			lastReport = Date()
		}
	}

	private func copy(from base: UnsafeMutableRawPointer, bytesPerRow: Int) {
		guard let previous else { return }
		let rowBytes = width * 4
		for line in 0..<height {
			(previous + line * rowBytes).copyMemory(from: base + line * bytesPerRow, byteCount: rowBytes)
		}
	}
}
