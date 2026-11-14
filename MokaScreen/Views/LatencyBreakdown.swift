// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Charts
import SwiftUI

/// The whole trip from capture to the other Mac's screen, split into its two halves: capture
/// and the cable on this Mac's side, and the display Mac's share from its once-a-second report.
/// Shown in the extending Mac's window when Show Statistics is on.
struct LatencyBreakdown: View {
	/// Seconds of history charted.
	static let historyLength = 60

	/// The latest second.
	let stats: SenderSnapshot
	/// One snapshot a second while connected, oldest first.
	let history: [SenderSnapshot]
	let refreshRate: Int

	/// One refresh interval in milliseconds: the yardstick the figures are judged against.
	private var frameBudget: Double { 1000 / Double(max(refreshRate, 1)) }
	private var total: Double { stats.recentLatency }
	private var parts: TripParts { Self.parts(of: stats) }
	private var hasReport: Bool { stats.displayDelay > 0 }
	private var showsSmoothMotion: Bool { stats.displayPacing > 0 || history.contains { $0.displayPacing > 0 } }

	/// A trip from capture to glass split into its parts, in milliseconds.
	struct TripParts: Equatable {
		var captureAndCable: Double
		/// The display Mac's own share: drawing and waiting for the panel.
		var display: Double
		/// The time Smooth Motion held the frame before drawing it; zero while it is off.
		var smoothMotion: Double
	}

	/// Splits a second's typical trip. The display Mac reports its share (arrival to glass) and the
	/// wait between a frame's arrival and its draw; under Smooth Motion that wait is the hold, so it
	/// is shown apart from the display Mac's own work.
	static func parts(of stats: SenderSnapshot) -> TripParts {
		let total = stats.recentLatency
		let display = min(stats.displayDelay, total)
		let hold = stats.displayPacing > 0 ? min(stats.displayWait, display) : 0
		return TripParts(captureAndCable: max(0, total - display), display: display - hold, smoothMotion: hold)
	}

	/// Whether a frame has reached the display Mac's screen in the latest second or the charted
	/// minute. Until then the panel has nothing to show and is left out.
	static func hasMeasurements(stats: SenderSnapshot, history: [SenderSnapshot]) -> Bool {
		stats.recentLatency > 0 || history.contains { $0.recentLatency > 0 }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			headline
			if total > 0 {
				SplitBar(parts: parts, hasReport: hasReport, frameBudget: frameBudget)
			}
			VStack(spacing: 8) {
				legend
				chart
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
	}

	private var headline: some View {
		HStack(alignment: .lastTextBaseline) {
			HStack(alignment: .lastTextBaseline, spacing: 3) {
				Text(total > 0 ? String(format: "%.1f", total) : "—")
					.font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
					.foregroundStyle(tint)
					.contentTransition(.numericText())
					.animation(.snappy, value: total)
				Text("ms")
					.font(.system(size: 17, weight: .medium, design: .rounded))
					.foregroundStyle(.secondary)
			}
			Spacer()
			VStack(alignment: .trailing, spacing: 2) {
				Self.sectionLabel("CAPTURE → ON GLASS")
				if total > 0 {
					Text(String(format: "%.2f refreshes at %d Hz", total / frameBudget, refreshRate))
						.font(.callout.monospacedDigit())
					Text(String(format: "p99 %.1f ms", stats.recentLatencyP99))
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	private var legend: some View {
		HStack(spacing: 10) {
			Self.sectionLabel("LAST MINUTE")
				.fixedSize()
			Spacer()
			LegendSwatch(label: "Capture + cable", color: Self.captureColor)
			if showsSmoothMotion {
				LegendSwatch(label: "Smooth Motion", color: Self.smoothMotionColor)
			}
			LegendSwatch(label: "Display Mac", color: Self.displayColor)
			LegendSwatch(label: "Refreshes", color: .secondary, dashed: true)
		}
	}

	private var chart: some View {
		// The newest second is always at the right edge, so a new connection's line starts
		// part-way across rather than growing rightwards from the left.
		let offset = Self.historyLength - history.count
		let seconds = Array(history.enumerated())
		let peak = history.map(\.recentLatency).max() ?? 0
		let refreshes = Int(max(2, (peak / frameBudget).rounded(.up)))
		return Chart {
			ForEach(seconds, id: \.offset) { index, second in
				if second.recentLatency > 0 {
					let parts = Self.parts(of: second)
					AreaMark(x: .value("Second", index + offset), y: .value("ms", parts.display), stacking: .standard)
						.foregroundStyle(by: .value("Part", "Display Mac"))
						.interpolationMethod(.monotone)
					AreaMark(x: .value("Second", index + offset), y: .value("ms", parts.smoothMotion), stacking: .standard)
						.foregroundStyle(by: .value("Part", "Smooth Motion"))
						.interpolationMethod(.monotone)
					AreaMark(x: .value("Second", index + offset), y: .value("ms", parts.captureAndCable), stacking: .standard)
						.foregroundStyle(by: .value("Part", "Capture + cable"))
						.interpolationMethod(.monotone)
				}
			}
			ForEach(1...refreshes, id: \.self) { n in
				RuleMark(y: .value("Refresh", Double(n) * frameBudget))
					.lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 4]))
					.foregroundStyle(.secondary.opacity(0.6))
			}
		}
		.chartForegroundStyleScale(["Display Mac": Self.displayColor.gradient, "Smooth Motion": Self.smoothMotionColor.gradient, "Capture + cable": Self.captureColor.gradient])
		.chartXScale(domain: 0...(Self.historyLength - 1))
		.chartYScale(domain: 0...(Double(refreshes) * frameBudget))
		.chartXAxis(.hidden)
		.chartYAxis(.hidden)
		.chartLegend(.hidden)
		.frame(height: 64)
	}

	private var tint: Color {
		Self.tint(total: total, smoothMotionDelay: stats.displayPacing, frameBudget: frameBudget)
	}

	/// Green within two refreshes beyond Smooth Motion's delay, amber within three, red beyond.
	/// Without Smooth Motion that is two and three refreshes: a full-screen change takes about
	/// 3.6 ms on the cable and then the display Mac's next refresh, about one and a half refreshes
	/// in all; 0.1.8's display-link path took about two and a half. Smooth Motion's delay is chosen
	/// (20 ms by default), so it is allowed for, and the colour says whether frames are reaching
	/// the glass when Smooth Motion schedules them rather than whether the delay is small.
	static func tint(total: Double, smoothMotionDelay: Double, frameBudget: Double) -> Color {
		guard total > 0 else { return .secondary }
		let allowed = max(0, smoothMotionDelay)
		if total <= allowed + frameBudget * 2 { return .green }
		if total <= allowed + frameBudget * 3 { return .orange }
		return .red
	}

	private static func sectionLabel(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 10, weight: .bold, design: .rounded))
			.tracking(1.1)
			.foregroundStyle(.secondary)
	}

	static let captureColor = Color.teal
	static let smoothMotionColor = Color.purple.opacity(0.55)
	static let displayColor = Color.indigo
}

/// The latest trip as one bar split into its parts, with a tick at every refresh. The track
/// spans two refreshes, and grows when a trip takes longer.
private struct SplitBar: View {
	let parts: LatencyBreakdown.TripParts
	/// False before the display Mac's first report, when the whole trip is shown as capture + cable.
	let hasReport: Bool
	let frameBudget: Double

	var body: some View {
		let total = parts.captureAndCable + (hasReport ? parts.smoothMotion + parts.display : 0)
		let scale = max(total, frameBudget * 2)
		VStack(alignment: .leading, spacing: 6) {
			GeometryReader { proxy in
				let width = proxy.size.width
				ZStack(alignment: .leading) {
					Capsule().fill(.quaternary)
					// In the order a frame goes through them: captured and sent, held, drawn.
					HStack(spacing: 2) {
						Rectangle()
							.fill(LatencyBreakdown.captureColor.gradient)
							.frame(width: width * parts.captureAndCable / scale)
						if hasReport {
							if parts.smoothMotion > 0 {
								Rectangle()
									.fill(LatencyBreakdown.smoothMotionColor.gradient)
									.frame(width: max(0, width * parts.smoothMotion / scale - 2))
							}
							Rectangle()
								.fill(LatencyBreakdown.displayColor.gradient)
								.frame(width: max(0, width * parts.display / scale - 2))
						}
					}
					.clipShape(.capsule)
					ForEach(1..<Int(scale / frameBudget) + 1, id: \.self) { n in
						Rectangle()
							.fill(.background.opacity(0.7))
							.frame(width: 1)
							.offset(x: width * Double(n) * frameBudget / scale)
					}
				}
			}
			.frame(height: 10)
			HStack(spacing: 14) {
				part("Capture + cable", parts.captureAndCable, color: LatencyBreakdown.captureColor)
				Spacer()
				if hasReport {
					if parts.smoothMotion > 0 {
						part("Smooth Motion", parts.smoothMotion, color: LatencyBreakdown.smoothMotionColor)
					}
					part("Display Mac", parts.display, color: LatencyBreakdown.displayColor)
				} else {
					Text("Waiting for the display Mac…")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	private func part(_ label: String, _ milliseconds: Double, color: Color) -> some View {
		HStack(spacing: 5) {
			Circle().fill(color).frame(width: 7, height: 7)
			Text(label).foregroundStyle(.secondary)
			Text(String(format: "%.1f ms", milliseconds)).monospacedDigit()
		}
		.font(.caption)
	}
}

/// A small colour sample and its name, for the chart's legend.
private struct LegendSwatch: View {
	let label: String
	let color: Color
	var dashed = false

	var body: some View {
		HStack(spacing: 5) {
			if dashed {
				Path { path in
					path.move(to: CGPoint(x: 0, y: 1))
					path.addLine(to: CGPoint(x: 12, y: 1))
				}
				.stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
				.frame(width: 12, height: 2)
			} else {
				RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
			}
			Text(label)
				.font(.caption2)
				.lineLimit(1)
				.fixedSize()
				.foregroundStyle(.secondary)
		}
	}
}
