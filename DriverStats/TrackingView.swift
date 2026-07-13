//
//  TrackingView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import SwiftUI
import UIKit

struct TrackingView: View {
    @ObservedObject var motion: MotionManager
    @ObservedObject var location: LocationManager
    @Binding var isTracking: Bool

    @AppStorage("ds.keepScreenOn") private var keepScreenOn: Bool = false
    @AppStorage("ds.feltDirection") private var feltDirection: Bool = false
    @State private var sessionResult: SessionResult? = nil

    private var stats: SessionStats? { motion.sessionStats }

    var body: some View {
        TabView {
            timerSpeedPage
            ggPage
            sessionStatsPage
            headingPage
        }
        .background(Color(.systemBackground))
        .scrollContentBackground(.hidden)
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .indexViewStyle(.page(backgroundDisplayMode: .never))
        .navigationTitle("Driving")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: stopSession) {
                Text("Stop & Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.red)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = .label
            UIPageControl.appearance().pageIndicatorTintColor = .tertiaryLabel
            if keepScreenOn { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onDisappear {
            UIPageControl.appearance().currentPageIndicatorTintColor = nil
            UIPageControl.appearance().pageIndicatorTintColor = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $sessionResult, onDismiss: { isTracking = false }) { result in
            SessionResultsView(result: result)
        }
    }

    // MARK: - Page 1: Timer + Speed

    private var timerSpeedPage: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("REC")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                }
                Text(stats.map { formatDuration($0.durationSeconds) } ?? "0:00")
                    .font(.system(size: 64, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color(.label))
            }
            Spacer()
            Dial(
                value: max(0, location.speed * 3.6),
                max: 200,
                unit: "km/h",
                label: "speed",
                size: 220,
                zone: .accentColor,
                bigValue: true
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Page 2: G-G Diagram + Live & Peak

    private var ggPage: some View {
        GeometryReader { geo in
            let diagramSize = min(geo.size.width - 32, geo.size.height * 0.48)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("g-g Diagram")
                            .font(.footnote.weight(.medium))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .tracking(0.3)
                        Spacer()
                        Text("live")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                    GGDiagram(
                        points: ggTrail,
                        gmax: 0.7,
                        size: diagramSize,
                        showTrail: true,
                        current: ggCurrent,
                        isFelt: feltDirection
                    )
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Axis")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Live")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .trailing)
                            Text("Peak")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 82, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider()

                        gTableRow("Forward",  liveValue: liveForwardStr,  peakValue: peakForwardStr)
                        gTableRow("Lateral",  liveValue: liveLateralStr,  peakValue: peakLateralStr)
                        gTableRow("Vertical", liveValue: liveVerticalStr, peakValue: peakVerticalStr)
                        gTableRow("Net",      liveValue: liveNetStr,      peakValue: peakNetStr, isLast: true)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
                .frame(minHeight: geo.size.height)
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Page 3: Session Stats

    private var sessionStatsPage: some View {
        ScrollView {
            VStack(spacing: 16) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                    spacing: 10
                ) {
                    StatCell(label: "Distance",    value: stats.map { formatDistance($0.totalDistanceM) } ?? "—",        cardBackground: Color(.secondarySystemBackground))
                    StatCell(label: "Moving time", value: stats.map { formatDuration($0.movingTimeSeconds) } ?? "—",     cardBackground: Color(.secondarySystemBackground))
                    StatCell(label: "Max speed",   value: stats.map { String(format: "%.0f km/h", $0.maxSpeedMps * 3.6) } ?? "—", cardBackground: Color(.secondarySystemBackground))
                    StatCell(label: "Stops",       value: stats.map { "\($0.stopCount)" } ?? "—",                        cardBackground: Color(.secondarySystemBackground))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Hard Events")
                            .font(.footnote.weight(.medium))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .tracking(0.3)
                        Spacer()
                        Text(String(format: "threshold %.2f g", motion.hardThresholdG))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                        spacing: 10
                    ) {
                        StatCell(label: "Accel",  value: "\(stats?.hardAccelCount ?? 0)",     accent: true, cardBackground: Color(.secondarySystemBackground))
                        StatCell(label: "Brake",  value: "\(stats?.hardBrakingCount ?? 0)",   accent: true, cardBackground: Color(.secondarySystemBackground))
                        StatCell(label: "Corner", value: "\(stats?.hardCorneringCount ?? 0)", accent: true, cardBackground: Color(.secondarySystemBackground))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Page 4: Heading Debug

    private var headingPage: some View {
        List {
            Section("Heading Source") {
                LabeledContent("Mode",                value: headingMode)
                LabeledContent("Base GPS / estimate", value: headingBaseEst)
                LabeledContent("GPS age",             value: headingGpsAge)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - G Table Row

    @ViewBuilder
    private func gTableRow(_ label: String, liveValue: String, peakValue: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(label)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(liveValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .trailing)
                Text(peakValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 82, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            if !isLast {
                Divider().padding(.leading, 16)
            }
        }
    }

    // MARK: - Live G values

    private var liveForwardStr: String {
        let s = feltDirection ? -1.0 : 1.0
        return motion.displayAcceleration.map { String(format: "%+.2f g", $0.forward * s) } ?? "—"
    }

    private var liveLateralStr: String {
        let s = feltDirection ? -1.0 : 1.0
        return motion.displayAcceleration.map { String(format: "%+.2f g", $0.lateral * s) } ?? "—"
    }

    private var liveVerticalStr: String {
        motion.displayAcceleration.map { String(format: "%+.2f g", $0.vertical) } ?? "—"
    }

    private var liveNetStr: String {
        motion.displayAcceleration.map { a in
            let net = (a.forward * a.forward + a.lateral * a.lateral + a.vertical * a.vertical).squareRoot()
            return String(format: "%.2f g", net)
        } ?? "—"
    }

    // MARK: - Peak G values (session max in each axis)

    private var peakForwardStr: String {
        guard let s = stats else { return "—" }
        return String(format: "%.2f g", max(s.peakForward, abs(s.peakBraking)))
    }

    private var peakLateralStr: String {
        guard let s = stats else { return "—" }
        return String(format: "%.2f g", max(abs(s.peakRight), abs(s.peakLeft)))
    }

    private var peakVerticalStr: String {
        guard let s = stats else { return "—" }
        return String(format: "%.2f g", max(s.peakUp, abs(s.peakDown)))
    }

    private var peakNetStr: String {
        stats.map { String(format: "%.2f g", $0.peakNetAccel) } ?? "—"
    }

    // MARK: - GG helpers

    private var ggTrail: [GGPoint] {
        let s = feltDirection ? -1.0 : 1.0
        return motion.recentSamples.map { GGPoint(lat: $0.lateral * s, fwd: $0.forward * s) }
    }

    private var ggCurrent: GGPoint? {
        guard let a = motion.displayAcceleration else { return nil }
        let s = feltDirection ? -1.0 : 1.0
        return GGPoint(lat: a.lateral * s, fwd: a.forward * s)
    }

    // MARK: - Heading helpers

    private var headingMode: String {
        switch motion.headingStatus {
        case .noFix: return "No fix"
        case .gpsFix: return "GPS direct"
        case .propagated: return "Gyro-propagated"
        }
    }

    private var headingBaseEst: String {
        switch motion.headingStatus {
        case .noFix: return "—"
        case .gpsFix(let c, _, _): return String(format: "%.0f°", c)
        case .propagated(let b, let cur, _): return String(format: "%.0f° / %.0f°", b, cur)
        }
    }

    private var headingGpsAge: String {
        switch motion.headingStatus {
        case .noFix: return "—"
        case .gpsFix: return "< 1.5 s"
        case .propagated(_, _, let age): return String(format: "%.1f s", age)
        }
    }

    // MARK: - Stop

    private func stopSession() {
        motion.endSession()
        location.stopTrack()
        guard let stats = motion.sessionStats else { return }
        sessionResult = SessionResult(
            stats: stats,
            track: location.trackPoints,
            peakEvents: motion.peakEvents,
            ggSamples: motion.ggSamples,
            rawFwd: motion.rawSessionFwd,
            rawLat: motion.rawSessionLat,
            rawVert: motion.rawSessionVert,
            lapSplits: location.lapSplits
        )
    }
}
