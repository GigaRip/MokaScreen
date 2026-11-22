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
	/// ScreenCaptureKit's presentation time for the frame, in host nanoseconds: the virtual
	/// display's refresh the frame belongs to. It lies on the display's 120 Hz ticks to within
	/// 0.03 ms, and ScreenCaptureKit hands the frame over a median 3 ms before it (up to 7 ms; frame
	/// timing recording of 2026-11-21), so it is not the time the frame reached MokaScreen.
	let captureTime: UInt64
	/// Host time at which ScreenCaptureKit handed the frame over, in nanoseconds; nil for a frame
	/// sent again later, such as the last picture at the start of a connection.
	var handoffTime: UInt64?
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

/// Captures one display with ScreenCaptureKit, a frame for every refresh in which it changed.
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
		// Half a refresh, so the limit never binds: the display has a new picture at most every
		// 1/120 s. With the limit at exactly 1/120 s, frames of a scroll were handed over every
		// 8.8 ms rather than 8.33 (recordings of 2026-11-14 and 2026-11-21): each came 0.45 ms later
		// against its refresh than the one before, until a refresh was skipped about every fifteenth
		// frame. Whether the limit caused that is what this setting tests.
		config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
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
		onFrame(CapturedFrame(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer, dirtyRects: dirtyRects, captureTime: captureTime, handoffTime: HostClock.now))
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		Log.capture.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
		guard self.stream === stream else { return }
		self.stream = nil
		onStop(error)
	}
}
