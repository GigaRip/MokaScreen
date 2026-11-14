// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Testing
@testable import MokaScreen

@Suite struct FrameTimingRecorderTests {
	private let ms: UInt64 = 1_000_000

	@Test func joinsCapturesSendsAndDisplayReports() {
		let base: UInt64 = 1_000_000 * ms
		let captures = [
			FrameTimingRecorder.Capture(captureTime: base, submitTime: base + ms, dirtyRects: 3),
			// Replaced by the next capture before it could be sent.
			FrameTimingRecorder.Capture(captureTime: base + 8_333_333, submitTime: base + 9 * ms, dirtyRects: 2),
			FrameTimingRecorder.Capture(captureTime: base + 16_666_667, submitTime: base + 17 * ms, dirtyRects: 2),
			// Sent, but its drawable was never shown.
			FrameTimingRecorder.Capture(captureTime: base + 25 * ms, submitTime: base + 26 * ms, dirtyRects: 1),
		]
		let sends = [
			FrameTimingRecorder.Send(frameID: 1, captureTime: base, startTime: base + 2 * ms, endTime: base + 4 * ms, bytes: 1000, rects: 3, coverage: 0.5),
			FrameTimingRecorder.Send(frameID: 2, captureTime: base + 16_666_667, startTime: base + 18 * ms, endTime: base + 19 * ms, bytes: 500, rects: 2, coverage: 0.25),
			FrameTimingRecorder.Send(frameID: 3, captureTime: base + 25 * ms, startTime: base + 27 * ms, endTime: base + 28 * ms, bytes: 100, rects: 1, coverage: 0.05),
		]
		let displayBase: UInt64 = 5_000 * ms
		let displays = [
			FrameTimingMessage(frameID: 1, drawTime: displayBase + ms, receivedBeforeDrawMicros: 1000, glassAfterDrawMicros: 7000, drawnTogether: 1, paced: false),
			FrameTimingMessage(frameID: 2, drawTime: displayBase + 18 * ms, receivedBeforeDrawMicros: 500, glassAfterDrawMicros: 6000, drawnTogether: 1, paced: true),
			FrameTimingMessage(frameID: 3, drawTime: displayBase + 30 * ms, receivedBeforeDrawMicros: 200, glassAfterDrawMicros: -1, drawnTogether: 1, paced: false),
		]

		let rows = FrameTimingRecorder.csv(captures: captures, sends: sends, displays: displays)
			.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
		#expect(rows.first?.joined(separator: ",") == FrameTimingRecorder.csvHeader)
		#expect(rows.count == 5)
		#expect(rows.dropFirst().allSatisfy { $0.count == 16 })

		// First frame: received at the display origin, on glass 8 ms later.
		#expect(rows[1][0] == "0.000")
		#expect(rows[1][4] == "1")
		#expect(rows[1][10] == "0.000")
		#expect(rows[1][12] == "8.000")
		// The replaced capture has no frame ID and nothing after it.
		#expect(rows[2][1] == "8.333")
		#expect(rows[2][4...].allSatisfy { $0.isEmpty })
		// Second frame: on glass at 24.0 ms, 16 ms after the first; paced.
		#expect(rows[3][12] == "24.000")
		#expect(rows[3][13] == "16.000")
		#expect(rows[3][15] == "1")
		// Third frame: drawn, never shown.
		#expect(rows[4][11] == "30.000")
		#expect(rows[4][12].isEmpty)
	}

	@Test func recordsOnlyWhileActiveAndDropsPastCapacity() {
		let recorder = FrameTimingRecorder()
		recorder.record(FrameTimingRecorder.Capture(captureTime: 1, submitTime: 1, dirtyRects: 0))
		#expect(recorder.captures.snapshot().isEmpty)
		recorder.start()
		for i in 0..<(FrameTimingRecorder.capacity + 10) {
			recorder.record(FrameTimingRecorder.Capture(captureTime: UInt64(i), submitTime: UInt64(i), dirtyRects: 0))
		}
		#expect(recorder.captures.snapshot().count == FrameTimingRecorder.capacity)
		recorder.start()
		#expect(recorder.captures.snapshot().isEmpty)
	}
}
