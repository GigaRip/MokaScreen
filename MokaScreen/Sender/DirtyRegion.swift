// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreGraphics

/// An integer pixel rectangle.
struct PixelRect: Equatable, CustomStringConvertible {
	var x: Int
	var y: Int
	var width: Int
	var height: Int

	var area: Int { width * height }

	var description: String { "(\(x),\(y) \(width)×\(height))" }
}

/// The set of display pixels that changed since the receiver was last brought up to date.
///
/// Changes are tracked on a grid of square tiles. Folding every dirty rectangle into the
/// grid gives three properties the sender relies on:
/// - Dirty rectangles from frames dropped by latest-frame-wins merge for free.
/// - ``rectangles()`` returns *disjoint* rectangles, so a frame's payload never exceeds one
///   full display — the receiver sizes its buffers on that guarantee.
/// - Many small or overlapping updates collapse into a few tile-aligned rectangles, which
///   bounds per-rectangle overhead at the cost of at most one tile of overdraw per edge.
struct DirtyRegion {
	let width: Int
	let height: Int
	let tileSize: Int
	let columns: Int
	let rows: Int
	private var tiles: [Bool]
	private(set) var dirtyTileCount = 0

	/// Creates an empty region for a `width × height` display.
	init(width: Int, height: Int, tileSize: Int = 32) {
		precondition(width > 0 && height > 0 && tileSize > 0)
		self.width = width
		self.height = height
		self.tileSize = tileSize
		columns = (width + tileSize - 1) / tileSize
		rows = (height + tileSize - 1) / tileSize
		tiles = Array(repeating: false, count: columns * rows)
	}

	var isEmpty: Bool { dirtyTileCount == 0 }

	/// Fraction of the display's tiles that are dirty, 0...1.
	var dirtyFraction: Double { Double(dirtyTileCount) / Double(tiles.count) }

	/// Marks every tile `rect` touches. Parts outside the display are ignored.
	mutating func insert(_ rect: CGRect) {
		let clipped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: width, height: height))
		guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
		let c0 = Int(clipped.minX.rounded(.down)) / tileSize
		let r0 = Int(clipped.minY.rounded(.down)) / tileSize
		let c1 = (Int(clipped.maxX.rounded(.up)) - 1) / tileSize
		let r1 = (Int(clipped.maxY.rounded(.up)) - 1) / tileSize
		for r in r0...r1 {
			let base = r * columns
			for c in c0...c1 where !tiles[base + c] {
				tiles[base + c] = true
				dirtyTileCount += 1
			}
		}
	}

	/// Marks the whole display dirty.
	mutating func insertAll() {
		for i in tiles.indices { tiles[i] = true }
		dirtyTileCount = tiles.count
	}

	/// Merges another region of the same geometry.
	mutating func formUnion(_ other: DirtyRegion) {
		precondition(other.columns == columns && other.rows == rows)
		for i in tiles.indices where other.tiles[i] && !tiles[i] {
			tiles[i] = true
			dirtyTileCount += 1
		}
	}

	mutating func removeAll() {
		guard dirtyTileCount > 0 else { return }
		for i in tiles.indices { tiles[i] = false }
		dirtyTileCount = 0
	}

	/// Whether the tile at `column`, `row` is dirty.
	func containsTile(column: Int, row: Int) -> Bool {
		tiles[row * columns + column]
	}

	/// Disjoint rectangles that exactly cover the dirty tiles, clipped to the display.
	///
	/// Each tile row is split into horizontal runs; a run extends the rectangle above it when
	/// both span the same columns. Full-width updates therefore become one rectangle whose
	/// rows are contiguous in the capture buffer, which the sender writes with a single iovec.
	func rectangles() -> [PixelRect] {
		guard dirtyTileCount > 0 else { return [] }
		var result: [PixelRect] = []
		// Open rectangles from the previous tile row, keyed by (first column, last column).
		var open: [Int: Int] = [:]
		for r in 0..<rows {
			var next: [Int: Int] = [:]
			var c = 0
			let base = r * columns
			while c < columns {
				guard tiles[base + c] else { c += 1; continue }
				let start = c
				while c < columns, tiles[base + c] { c += 1 }
				let key = start << 16 | (c - 1)
				if let index = open[key] {
					result[index].height += tileSize
					next[key] = index
				} else {
					result.append(PixelRect(x: start * tileSize, y: r * tileSize, width: (c - start) * tileSize, height: tileSize))
					next[key] = result.count - 1
				}
			}
			open = next
		}
		for i in result.indices {
			result[i].width = min(result[i].width, width - result[i].x)
			result[i].height = min(result[i].height, height - result[i].y)
		}
		return result
	}
}
