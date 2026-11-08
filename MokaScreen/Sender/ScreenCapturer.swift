// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// One captured frame: the full display image plus the rectangles that changed since the
/// previous captured frame.
struct CapturedFrame: @unchecked Sendable {
	/// Retained so ScreenCaptureKit does not recycle the pixel buffer while it is being sent.
	let sampleBuffer: CMSampleBuffer
	let pixelBuffer: CVPixelBuffer
	/// Changed areas in pixel coordinates of `pixelBuffer`.
	let dirtyRects: [CGRect]
	/// Host time of capture, in nanoseconds.
	let captureTime: UInt64
}

/// Errors starting capture.
enum CaptureError: Error, CustomStringConvertible {
	case permissionDenied
	case displayNotFound

	var description: String {
		switch self {
		case .permissionDenied: "MokaScreen needs Screen Recording permission"
		case .displayNotFound: "ScreenCaptureKit cannot see the virtual display"
		}
	}
}

/// Captures one display with ScreenCaptureKit at up to 120 frames per second.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
	private let displayID: CGDirectDisplayID
	private let width: Int
	private let height: Int
	private let onFrame: (CapturedFrame) -> Void
	private let onStop: (Error?) -> Void
	private let queue = DispatchQueue(label: "com.gigarip.mokascreen.capture", qos: .userInteractive)
	private var stream: SCStream?

	/// - Parameters:
	///   - onFrame: Called on a private serial queue for every frame whose content changed.
	///   - onStop: Called if the stream stops for any reason other than ``stop()``.
	init(displayID: CGDirectDisplayID, width: Int, height: Int, onFrame: @escaping (CapturedFrame) -> Void, onStop: @escaping (Error?) -> Void) {
		self.displayID = displayID
		self.width = width
		self.height = height
		self.onFrame = onFrame
		self.onStop = onStop
	}

	/// Starts capturing. A newly created virtual display can take a moment to appear in
	/// ScreenCaptureKit's shareable content, so this retries briefly before giving up.
	func start() async throws {
		guard CGPreflightScreenCaptureAccess() else {
			CGRequestScreenCaptureAccess()
			throw CaptureError.permissionDenied
		}
		var scDisplay: SCDisplay?
		for _ in 0..<30 {
			let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
			scDisplay = content.displays.first { $0.displayID == displayID }
			if scDisplay != nil { break }
			try await Task.sleep(for: .milliseconds(100))
		}
		guard let scDisplay else { throw CaptureError.displayNotFound }

		let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
		let config = SCStreamConfiguration()
		config.width = width
		config.height = height
		config.scalesToFit = false
		config.pixelFormat = kCVPixelFormatType_32BGRA
		config.colorSpaceName = CGColorSpace.displayP3
		config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
		config.showsCursor = true
		config.capturesAudio = false
		// The sender holds at most three buffers at once (the newest capture, the frame being
		// written, and the last complete frame for reconnects); a deeper pool keeps
		// ScreenCaptureKit from stalling while they are out.
		config.queueDepth = 6

		let stream = SCStream(filter: filter, configuration: config, delegate: self)
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
		try await stream.startCapture()
		self.stream = stream
		Log.capture.info("Capturing display \(self.displayID, privacy: .public) at \(self.width, privacy: .public)×\(self.height, privacy: .public)")
	}

	/// Stops capturing.
	func stop() async {
		guard let stream else { return }
		self.stream = nil
		try? await stream.stopCapture()
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen,
		      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
		      let info = attachments.first,
		      let statusValue = info[.status] as? Int,
		      SCFrameStatus(rawValue: statusValue) == .complete,
		      let pixelBuffer = sampleBuffer.imageBuffer
		else { return }

		let dirtyRects = (info[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) }
			?? [CGRect(x: 0, y: 0, width: width, height: height)]
		let pts = sampleBuffer.presentationTimeStamp
		let captureTime = pts.isValid ? UInt64(max(0, pts.seconds) * 1e9) : HostClock.now
		onFrame(CapturedFrame(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer, dirtyRects: dirtyRects, captureTime: captureTime))
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		Log.capture.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
		guard self.stream === stream else { return }
		self.stream = nil
		onStop(error)
	}
}
