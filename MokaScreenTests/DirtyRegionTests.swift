// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreGraphics
import Testing
@testable import MokaScreen

struct DirtyRegionTests {
	@Test func emptyRegionHasNoRectangles() {
		let region = DirtyRegion(width: 3456, height: 2234)
		#expect(region.isEmpty)
		#expect(region.rectangles().isEmpty)
	}

	@Test func smallRectSnapsToOneTile() {
		var region = DirtyRegion(width: 3456, height: 2234, tileSize: 32)
		region.insert(CGRect(x: 40, y: 70, width: 5, height: 5))
		#expect(region.rectangles() == [PixelRect(x: 32, y: 64, width: 32, height: 32)])
	}

	@Test func fullDisplayIsOneRectangleClippedToEdges() {
		var region = DirtyRegion(width: 3456, height: 2234, tileSize: 32)
		region.insertAll()
		#expect(region.rectangles() == [PixelRect(x: 0, y: 0, width: 3456, height: 2234)])
		#expect(region.dirtyFraction == 1)
	}

	@Test func outOfBoundsRectIsIgnored() {
		var region = DirtyRegion(width: 100, height: 100, tileSize: 32)
		region.insert(CGRect(x: 200, y: 200, width: 10, height: 10))
		region.insert(CGRect(x: -50, y: -50, width: 10, height: 10))
		#expect(region.isEmpty)
	}

	@Test func edgeTileIsClipped() {
		var region = DirtyRegion(width: 100, height: 70, tileSize: 32)
		region.insert(CGRect(x: 99, y: 69, width: 1, height: 1))
		#expect(region.rectangles() == [PixelRect(x: 96, y: 64, width: 4, height: 6)])
	}

	@Test func verticallyAlignedRunsMerge() {
		var region = DirtyRegion(width: 320, height: 320, tileSize: 32)
		region.insert(CGRect(x: 64, y: 0, width: 64, height: 160))
		#expect(region.rectangles() == [PixelRect(x: 64, y: 0, width: 64, height: 160)])
	}

	@Test func rectanglesAreDisjointAndCoverExactlyTheDirtyTiles() {
		var region = DirtyRegion(width: 1000, height: 700, tileSize: 32)
		var generator = SystemRandomNumberGenerator()
		for _ in 0..<40 {
			region.insert(CGRect(
				x: Double.random(in: -50...1000, using: &generator),
				y: Double.random(in: -50...700, using: &generator),
				width: Double.random(in: 1...300, using: &generator),
				height: Double.random(in: 1...200, using: &generator)
			))
		}
		let rects = region.rectangles()
		var covered = Array(repeating: 0, count: region.columns * region.rows)
		for rect in rects {
			#expect(rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= 1000 && rect.y + rect.height <= 700)
			for row in (rect.y / 32)...((rect.y + rect.height - 1) / 32) {
				for column in (rect.x / 32)...((rect.x + rect.width - 1) / 32) {
					covered[row * region.columns + column] += 1
				}
			}
		}
		for row in 0..<region.rows {
			for column in 0..<region.columns {
				let expected = region.containsTile(column: column, row: row) ? 1 : 0
				#expect(covered[row * region.columns + column] == expected)
			}
		}
		let totalArea = rects.reduce(0) { $0 + $1.area }
		#expect(totalArea <= 1000 * 700)
	}

	@Test func unionMergesRegions() {
		var a = DirtyRegion(width: 320, height: 320, tileSize: 32)
		var b = DirtyRegion(width: 320, height: 320, tileSize: 32)
		a.insert(CGRect(x: 0, y: 0, width: 32, height: 32))
		b.insert(CGRect(x: 0, y: 0, width: 64, height: 32))
		a.formUnion(b)
		#expect(a.dirtyTileCount == 2)
	}
}
