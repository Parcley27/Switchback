//
//  TrackingView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import SwiftUI

struct TrackingView: View {
    @ObservedObject var motion: MotionManager
    @ObservedObject var location: LocationManager
    @Binding var isTracking: Bool

    @State private var sessionResult: SessionResult? = nil

    private var stats: SessionStats? { motion.sessionStats }

    var body: some View {
        List {

            // Large elapsed-time display
            Section {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("REC").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                    }
                    Text(stats.map { formatDuration($0.durationSeconds) } ?? "0:00")
                        .font(.system(size: 52, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color(.label))
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Speed dial
            Section {
                HStack {
                    Spacer()
                    Dial(value: max(0, location.speed * 3.6),
                         max: 200, unit: "km/h", label: "speed",
                         size: 190, zone: .accentColor, bigValue: true)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // g-g Diagram + live readout
            Section {
                HStack(alignment: .center, spacing: 14) {
                    GGDiagram(points: ggTrail, gmax: 0.7, size: 150,
                              showTrail: true, current: ggCurrent)
                    VStack(spacing: 0) {
                        liveRow("Forward", value: motion.displayAcceleration.map { signedG($0.forward) } ?? "—")
                        liveRow("Lateral",  value: motion.displayAcceleration.map { signedG($0.lateral) } ?? "—")
                        liveRow("Vertical", value: motion.displayAcceleration.map { signedG($0.vertical) } ?? "—")
                        liveRow("Net",      value: motion.displayAcceleration.map { netGStr($0) } ?? "—", isLast: true)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                HStack {
                    Text("g-g Diagram")
                    Spacer()
                    Text("live").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .textCase(nil)
            }

            // Session stats
            Section("Session") {
                LabeledContent("Distance",     value: stats.map { formatDistance($0.totalDistanceM) } ?? "—")
                LabeledContent("Moving time",  value: stats.map { formatDuration($0.movingTimeSeconds) } ?? "—")
                LabeledContent("Max speed",    value: stats.map { String(format: "%.0f km/h", $0.maxSpeedMps * 3.6) } ?? "—")
                LabeledContent("Stops",        value: stats.map { "\($0.stopCount)" } ?? "—")
            }

            // Hard events
            Section {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    StatCell(label: "Accel",  value: "\(stats?.hardAccelCount ?? 0)",     accent: true)
                    StatCell(label: "Brake",  value: "\(stats?.hardBrakingCount ?? 0)",   accent: true)
                    StatCell(label: "Corner", value: "\(stats?.hardCorneringCount ?? 0)", accent: true)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                HStack {
                    Text("Hard Events")
                    Spacer()
                    Text(String(format: "threshold %.2f g", motion.hardThresholdG))
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .textCase(nil)
            }

            // Heading source
            Section("Heading Source") {
                LabeledContent("Mode",               value: headingMode)
                LabeledContent("Base GPS / estimate", value: headingBaseEst)
                LabeledContent("GPS age",            value: headingGpsAge)
            }
        }
        .listStyle(.insetGrouped)
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
        .sheet(item: $sessionResult, onDismiss: { isTracking = false }) { result in
            SessionResultsView(result: result)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func liveRow(_ label: String, value: String, isLast: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.body).foregroundStyle(Color(.label))
            Spacer()
            Text(value).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
        if !isLast { Divider() }
    }

    private var ggTrail: [GGPoint] {
        motion.recentSamples.map { GGPoint(lat: $0.lateral, fwd: $0.forward) }
    }

    private var ggCurrent: GGPoint? {
        guard let a = motion.displayAcceleration else { return nil }
        return GGPoint(lat: a.lateral, fwd: a.forward)
    }

    private func signedG(_ v: Double) -> String { String(format: "%+.2f g", v) }

    private func netGStr(_ a: AccelerationComponents) -> String {
        let net = (a.forward * a.forward + a.lateral * a.lateral + a.vertical * a.vertical).squareRoot()
        return String(format: "%.2f g", net)
    }

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

    private func stopSession() {
        motion.endSession()
        guard let stats = motion.sessionStats else { return }
        sessionResult = SessionResult(
            stats: stats,
            track: location.trackPoints,
            peakEvents: motion.peakEvents,
            ggSamples: motion.ggSamples,
            rawFwd: motion.rawSessionFwd,
            rawLat: motion.rawSessionLat,
            rawVert: motion.rawSessionVert
        )
    }
}
