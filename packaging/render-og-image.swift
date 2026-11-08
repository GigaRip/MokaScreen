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
// Renders the 1200 × 630 social share card for mokascreen.com.
//
// Usage: packaging/render-og-image.swift <icon-1024.png> <output.png>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let icon = NSImage(contentsOfFile: arguments[1]) else {
	FileHandle.standardError.write(Data("usage: render-og-image.swift <icon-1024.png> <output.png>\n".utf8))
	exit(1)
}

let size = NSSize(width: 1200, height: 630)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor.white.setFill()
NSRect(origin: .zero, size: size).fill()

let iconSize: CGFloat = 300
icon.draw(in: NSRect(x: 110, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize))

let ink = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x1B / 255, alpha: 1)
let muted = NSColor(srgbRed: 0x71 / 255, green: 0x71 / 255, blue: 0x7A / 255, alpha: 1)
let title = NSAttributedString(string: "MokaScreen", attributes: [
	.font: NSFont.systemFont(ofSize: 84, weight: .bold),
	.foregroundColor: ink,
	.kern: -1.5,
])
title.draw(at: NSPoint(x: 470, y: 330))
let tagline = NSAttributedString(string: "Your second MacBook,\nas a 120 Hz display.", attributes: [
	.font: NSFont.systemFont(ofSize: 40, weight: .regular),
	.foregroundColor: muted,
])
tagline.draw(in: NSRect(x: 474, y: 190, width: 680, height: 120))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
