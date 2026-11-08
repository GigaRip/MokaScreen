#!/usr/bin/env swift
// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------
//
// Renders the MokaScreen icon: an extended display behind the Mac you work on,
// whose screen carries MokaRig's light, white on the same near-black squircle.
//
// Usage: packaging/render-app-icon.swift <output-dir>
// Writes the AppIcon.appiconset PNGs plus icon-1024.png (full bleed, for the site).

import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(size: Int, squircle: Bool) -> CGImage {
	let s = CGFloat(size)
	let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
	                        space: CGColorSpace(name: CGColorSpace.displayP3)!,
	                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	context.scaleBy(x: s / 1024, y: s / 1024)

	// macOS app icons sit inside a 824 pt grid on a 1024 canvas; the site uses the full canvas.
	let inset: CGFloat = squircle ? 100 : 0
	let tile = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
	let radius = tile.width * 0.2237
	let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
	context.addPath(shape)
	context.clip()
	context.setFillColor(CGColor(srgbRed: 0x17 / 255, green: 0x16 / 255, blue: 0x1A / 255, alpha: 1))
	context.fill(tile)

	// Everything below is laid out on a 1024 canvas and scaled into the tile.
	context.translateBy(x: tile.minX, y: tile.minY)
	context.scaleBy(x: tile.width / 1024, y: tile.height / 1024)

	let white = CGColor(gray: 1, alpha: 1)
	let background = CGColor(srgbRed: 0x17 / 255, green: 0x16 / 255, blue: 0x1A / 255, alpha: 1)
	let stroke: CGFloat = 64
	let size = CGSize(width: 500, height: 330)
	// The extended display sits up and to the right, behind the Mac you work on.
	let back = CGRect(origin: CGPoint(x: 512 - size.width / 2 + 96, y: 512 - size.height / 2 + 82), size: size)
	let front = back.offsetBy(dx: -192, dy: -164)

	context.setStrokeColor(white)
	context.setLineWidth(stroke)
	context.setLineJoin(.round)
	let backPath = CGPath(roundedRect: back, cornerWidth: 44, cornerHeight: 44, transform: nil)
	context.addPath(backPath)
	context.strokePath()
	// The front screen hides the back one where they overlap, plus a stroke-wide moat.
	let frontPath = CGPath(roundedRect: front, cornerWidth: 44, cornerHeight: 44, transform: nil)
	context.addPath(frontPath)
	context.setLineWidth(stroke * 2.4)
	context.setStrokeColor(background)
	context.strokePath()
	context.addPath(frontPath)
	context.setFillColor(background)
	context.fillPath()
	context.addPath(frontPath)
	context.setLineWidth(stroke)
	context.setStrokeColor(white)
	context.strokePath()

	let centre = CGPoint(x: front.midX, y: front.midY)
	let halo = CGGradient(colorsSpace: nil, colors: [
		CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0.15), CGColor(gray: 1, alpha: 0),
	] as CFArray, locations: [0, 0.6, 1])!
	context.drawRadialGradient(halo, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 150, options: [])
	let led = CGGradient(colorsSpace: nil, colors: [
		CGColor(gray: 1, alpha: 1), CGColor(srgbRed: 0.957, green: 0.961, blue: 0.969, alpha: 1), CGColor(srgbRed: 0.851, green: 0.863, blue: 0.882, alpha: 1),
	] as CFArray, locations: [0, 0.5, 1])!
	context.addEllipse(in: CGRect(x: centre.x - 72, y: centre.y - 72, width: 144, height: 144))
	context.clip()
	context.drawRadialGradient(led, startCenter: CGPoint(x: centre.x, y: centre.y + 16), startRadius: 0, endCenter: centre, endRadius: 94, options: [.drawsAfterEndLocation])

	return context.makeImage()!
}

func write(_ image: CGImage, to name: String) {
	let url = outputDirectory.appendingPathComponent(name)
	let rep = NSBitmapImageRep(cgImage: image)
	try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

try! FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
	let suffix = scale == 2 ? "@2x" : ""
	write(render(size: points * scale, squircle: true), to: "icon_\(points)x\(points)\(suffix).png")
}
write(render(size: 1024, squircle: false), to: "icon-1024.png")
