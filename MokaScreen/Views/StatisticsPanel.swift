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

/// One second of a latency measurement for a ``StatisticsPanel``; 0 when nothing was measured.
struct LatencySample {
	var p50: Double
	var p99: Double
}

/// What a ``StatisticsPanel`` shows, built from either Mac's statistics.
struct StatisticsPanelContent {
	/// Seconds of history charted.
	static let historyLength = 60

	/// What the large figure measures, such as "CAPTURE → ON GLASS".
	var latencyLabel: String
	/// The rolling latency recorded once a second, oldest first, for the chart. Because the
	/// rolling figure holds through idle seconds, the line runs on flat while nothing changes
	/// instead of breaking, and ends at the large figure.
	var history: [LatencySample]
	/// The large figure: median and p99 over the most recent frames, which hold steady while
	/// the screen is idle; nil before the first frame.
	var current: LatencySample?
	/// Label and value pairs listed under the chart.
	var figures: [(String, String)]
	var refreshRate: Int
	/// Whether frames moved in the last second.
	var isLive: Bool
	/// Up to this many refreshes the large figure is green; up to twice it, amber; beyond, red.
	var greenWithinFrames: Double
}

extension StatisticsPanelContent {
	/// The display Mac's view: its share of the delay, from the last byte received to on glass.
	init(receiver stats: ReceiverSnapshot, history: [ReceiverSnapshot], refreshRate: Int, source: String?) {
		var figures = [
			("RECEIVED", String(format: "%.0f fps  ·  %.2f Gbps", stats.receivedFPS, stats.gigabitsPerSecond)),
			("PRESENTED", String(format: "%.0f fps", stats.presentedFPS)),
		]
		if let source { figures.append(("SOURCE", source)) }
		self.init(
			latencyLabel: "ARRIVAL → ON GLASS",
			history: history.map { LatencySample(p50: $0.recentDelay, p99: $0.recentDelayP99) },
			current: stats.recentDelay > 0 ? LatencySample(p50: stats.recentDelay, p99: stats.recentDelayP99) : nil,
			figures: figures,
			refreshRate: refreshRate,
			isLive: stats.receivedFrames > 0 || stats.presentedFrames > 0,
			greenWithinFrames: 1
		)
	}

	/// The extending Mac's view: the whole trip, from capture to the other Mac's screen. It
	/// includes macOS's capture handoff and the display Mac's refresh, so it is judged against
	/// three refreshes rather than one.
	init(sender stats: SenderSnapshot, history: [SenderSnapshot], refreshRate: Int, display: String?) {
		var figures = [
			("CAPTURED", String(format: "%.0f fps", stats.capturedFPS)),
			("SENT", String(format: "%.0f fps  ·  %.2f Gbps", stats.sentFPS, stats.gigabitsPerSecond)),
			("CHANGED", String(format: "%.1f%% of screen", stats.meanCoverage * 100)),
		]
		if let display { figures.append(("DISPLAY", display)) }
		self.init(
			latencyLabel: "CAPTURE → ON GLASS",
			history: history.map { LatencySample(p50: $0.recentLatency, p99: $0.recentLatencyP99) },
			current: stats.recentLatency > 0 ? LatencySample(p50: stats.recentLatency, p99: stats.recentLatencyP99) : nil,
			figures: figures,
			refreshRate: refreshRate,
			isLive: stats.capturedFrames > 0 || stats.sentFrames > 0,
			greenWithinFrames: 3
		)
	}
}

/// A dark glass panel: a latency in large type, a minute of it as a chart against the
/// one-refresh budget, and the rates behind it.
struct StatisticsPanel: View {
	let content: StatisticsPanelContent

	/// One refresh interval in milliseconds: the yardstick every figure is judged against.
	private var frameBudget: Double { 1000 / Double(max(content.refreshRate, 1)) }
	private var isLive: Bool { content.isLive }
	private var refreshRate: Int { content.refreshRate }
	private var history: [LatencySample] { content.history }
	private var latest: LatencySample? { content.current }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header
			hero
			VStack(spacing: 8) {
				legend
				chart
			}
			Rectangle()
				.fill(.white.opacity(0.1))
				.frame(height: 1)
			figures
		}
		.padding(20)
		.frame(width: 340)
		.background {
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.fill(.black.opacity(0.62))
				.background(.ultraThinMaterial, in: .rect(cornerRadius: 22, style: .continuous))
		}
		.overlay {
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
		}
		.shadow(color: .black.opacity(0.55), radius: 32, y: 14)
		.environment(\.colorScheme, .dark)
	}

	private var header: some View {
		HStack(spacing: 8) {
			LiveDot(isLive: isLive)
			Text(isLive ? "LIVE" : "IDLE")
				.font(.system(size: 11, weight: .heavy, design: .rounded))
				.tracking(1.5)
				.foregroundStyle(isLive ? Color.green : .secondary)
			Text("MOKASCREEN")
				.font(.system(size: 11, weight: .semibold, design: .rounded))
				.tracking(3)
				.foregroundStyle(.white.opacity(0.45))
			Spacer()
			Text("\(refreshRate) Hz")
				.font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.background(.white.opacity(0.1), in: .capsule)
		}
	}

	private var hero: some View {
		HStack(alignment: .lastTextBaseline) {
			HStack(alignment: .lastTextBaseline, spacing: 4) {
				Text(latest.map { String(format: "%.1f", $0.p50) } ?? "—")
					.font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
					.foregroundStyle(heroGradient)
					.contentTransition(.numericText())
					.animation(.snappy, value: latest?.p50)
				Text("ms")
					.font(.system(size: 20, weight: .medium, design: .rounded))
					.foregroundStyle(.white.opacity(0.5))
			}
			Spacer()
			VStack(alignment: .trailing, spacing: 3) {
				Text(content.latencyLabel)
					.font(.system(size: 9.5, weight: .bold, design: .rounded))
					.tracking(1.2)
					.foregroundStyle(.white.opacity(0.45))
				if let latest {
					Text(String(format: "%.2f frames", latest.p50 / frameBudget))
						.font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
					Text(String(format: "p99 %.1f ms", latest.p99))
						.font(.system(size: 12, design: .rounded).monospacedDigit())
						.foregroundStyle(.white.opacity(0.55))
				}
			}
		}
	}

	private var chart: some View {
		let points = Array(history.enumerated())
		let ceiling = max(frameBudget * 2, (history.map(\.p99).max() ?? 0) * 1.15)
		return Chart {
			ForEach(points, id: \.offset) { index, second in
				if second.p50 > 0 {
					AreaMark(x: .value("Second", index), y: .value("p50", second.p50))
						.interpolationMethod(.monotone)
						.foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
					LineMark(x: .value("Second", index), y: .value("p50", second.p50), series: .value("Series", "p50"))
						.interpolationMethod(.monotone)
						.lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
						.foregroundStyle(tint)
					LineMark(x: .value("Second", index), y: .value("p99", second.p99), series: .value("Series", "p99"))
						.interpolationMethod(.monotone)
						.lineStyle(StrokeStyle(lineWidth: 1))
						.foregroundStyle(.white.opacity(0.3))
				}
			}
			// Drawn last so the area fill never hides it.
			RuleMark(y: .value("One frame", frameBudget))
				.lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
				.foregroundStyle(.white.opacity(0.4))
		}
		.chartXScale(domain: 0...(StatisticsPanelContent.historyLength - 1))
		.chartYScale(domain: 0...ceiling)
		.chartXAxis(.hidden)
		.chartYAxis(.hidden)
		.chartLegend(.hidden)
		.frame(height: 72)
	}

	private var legend: some View {
		HStack(spacing: 12) {
			Text("LAST MINUTE")
				.font(.system(size: 9.5, weight: .bold, design: .rounded))
				.tracking(1.2)
				.foregroundStyle(.white.opacity(0.45))
			Spacer()
			LegendKey(label: "p50", color: tint, width: 2)
			LegendKey(label: "p99", color: .white.opacity(0.4), width: 1)
			LegendKey(label: "1 frame", color: .white.opacity(0.45), width: 1, dashed: true)
		}
	}

	private var figures: some View {
		Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
			ForEach(content.figures, id: \.0) { label, value in
				figure(label, value)
			}
		}
	}

	private func figure(_ label: String, _ value: String) -> some View {
		GridRow {
			Text(label)
				.font(.system(size: 9.5, weight: .bold, design: .rounded))
				.tracking(1.2)
				.foregroundStyle(.white.opacity(0.45))
			Text(value)
				.font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
				.foregroundStyle(.white.opacity(0.9))
		}
	}

	/// Green within ``StatisticsPanelContent/greenWithinFrames`` refreshes, amber within twice
	/// that, red beyond.
	private var tint: Color {
		guard let delay = latest?.p50 else { return .green }
		let green = frameBudget * content.greenWithinFrames
		if delay <= green { return .green }
		if delay <= green * 2 { return .orange }
		return .red
	}

	private var heroGradient: LinearGradient {
		LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom)
	}
}

/// A short line sample and its name, for the chart's legend.
private struct LegendKey: View {
	let label: String
	let color: Color
	let width: CGFloat
	var dashed = false

	var body: some View {
		HStack(spacing: 5) {
			Path { path in
				path.move(to: CGPoint(x: 0, y: 1))
				path.addLine(to: CGPoint(x: 12, y: 1))
			}
			.stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dashed ? [2, 3] : []))
			.frame(width: 12, height: 2)
			Text(label)
				.font(.system(size: 10, weight: .medium, design: .rounded))
				.foregroundStyle(.white.opacity(0.55))
		}
	}
}

/// A green dot with a slow ripple while frames are arriving.
private struct LiveDot: View {
	let isLive: Bool

	var body: some View {
		ZStack {
			if isLive {
				Circle()
					.fill(.green.opacity(0.5))
					.frame(width: 8, height: 8)
					.phaseAnimator([false, true]) { ripple, expanded in
						ripple
							.scaleEffect(expanded ? 2.6 : 1)
							.opacity(expanded ? 0 : 0.8)
					} animation: { expanded in
						expanded ? .easeOut(duration: 1.4) : .linear(duration: 0)
					}
			}
			Circle()
				.fill(isLive ? Color.green : .gray)
				.frame(width: 8, height: 8)
				.shadow(color: isLive ? .green.opacity(0.8) : .clear, radius: 4)
		}
		.frame(width: 10, height: 10)
	}
}
