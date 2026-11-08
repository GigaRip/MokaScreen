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
	private var display: Double { min(stats.displayDelay, total) }
	private var captureAndCable: Double { max(0, total - display) }
	private var hasReport: Bool { stats.displayDelay > 0 }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			headline
			if total > 0 {
				SplitBar(captureAndCable: captureAndCable, display: hasReport ? display : nil, frameBudget: frameBudget)
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
				Text("CAPTURE → ON GLASS")
					.font(.system(size: 10, weight: .bold, design: .rounded))
					.tracking(1.1)
					.foregroundStyle(.secondary)
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
		HStack(spacing: 12) {
			Text("LAST MINUTE")
				.font(.system(size: 10, weight: .bold, design: .rounded))
				.tracking(1.1)
				.foregroundStyle(.secondary)
			Spacer()
			LegendSwatch(label: "Capture + cable", color: Self.captureColor)
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
					let display = min(second.displayDelay, second.recentLatency)
					AreaMark(x: .value("Second", index + offset), y: .value("ms", display), stacking: .standard)
						.foregroundStyle(by: .value("Part", "Display Mac"))
						.interpolationMethod(.monotone)
					AreaMark(x: .value("Second", index + offset), y: .value("ms", second.recentLatency - display), stacking: .standard)
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
		.chartForegroundStyleScale(["Display Mac": Self.displayColor.gradient, "Capture + cable": Self.captureColor.gradient])
		.chartXScale(domain: 0...(Self.historyLength - 1))
		.chartYScale(domain: 0...(Double(refreshes) * frameBudget))
		.chartXAxis(.hidden)
		.chartYAxis(.hidden)
		.chartLegend(.hidden)
		.frame(height: 64)
	}

	/// Green within three refreshes, amber within four, red beyond: the floor is about two and a
	/// half, from macOS handing over the capture, the display Mac's next refresh, and its panel.
	private var tint: Color {
		guard total > 0 else { return .secondary }
		if total <= frameBudget * 3 { return .green }
		if total <= frameBudget * 4 { return .orange }
		return .red
	}

	static let captureColor = Color.teal
	static let displayColor = Color.indigo
}

/// The latest trip as one bar split into its two halves, with a tick at every refresh.
private struct SplitBar: View {
	let captureAndCable: Double
	/// Nil before the display Mac's first report.
	let display: Double?
	let frameBudget: Double

	var body: some View {
		let total = captureAndCable + (display ?? 0)
		let scale = max(total, frameBudget * 3)
		VStack(alignment: .leading, spacing: 6) {
			GeometryReader { proxy in
				let width = proxy.size.width
				ZStack(alignment: .leading) {
					Capsule().fill(.quaternary)
					HStack(spacing: 2) {
						Rectangle()
							.fill(LatencyBreakdown.captureColor.gradient)
							.frame(width: width * captureAndCable / scale)
						if let display {
							Rectangle()
								.fill(LatencyBreakdown.displayColor.gradient)
								.frame(width: max(0, width * display / scale - 2))
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
			HStack {
				part("Capture + cable", captureAndCable, color: LatencyBreakdown.captureColor)
				Spacer()
				if let display {
					part("Display Mac", display, color: LatencyBreakdown.displayColor)
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
				.foregroundStyle(.secondary)
		}
	}
}
