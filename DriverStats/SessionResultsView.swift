//
//  SessionResultsView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Charts
import MapKit
import SwiftData
import SwiftUI

// MARK: - Session Result model

struct SessionResult: Identifiable {
    let id = UUID()
    let stats: SessionStats
    let track: [RoutePoint]
    let peakEvents: [PeakEvent]
    var ggSamples: [GGPoint] = []
    var rawFwd: [Float] = []
    var rawLat: [Float] = []
    var rawVert: [Float] = []
}

// MARK: - Results sheet (shown immediately after Stop)

struct SessionResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let result: SessionResult

    @State private var didSave = false

    var body: some View {
        NavigationStack {
            DriveSessionContent(
                track: result.track,
                peakEvents: result.peakEvents,
                stats: result.stats,
                ggSamples: result.ggSamples
            )
            .navigationTitle("Drive Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                guard !didSave else { return }
                didSave = true
                modelContext.insert(DriveSession(result: result))
            }
        }
    }
}

// MARK: - Saved session detail (opened from History)

struct DriveSessionView: View {
    let session: DriveSession
    private var stats: SessionStats { SessionStats(restoringFrom: session) }

    var body: some View {
        DriveSessionContent(
            track: session.routePoints,
            peakEvents: session.peakEventsRestored,
            stats: stats,
            ggSamples: session.ggPointsStored
        )
        .navigationTitle("Drive Summary")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared visual content

private struct DriveSessionContent: View {
    let track: [RoutePoint]
    let peakEvents: [PeakEvent]
    let stats: SessionStats
    let ggSamples: [GGPoint]

    @AppStorage("ds.showDrivingScore") private var showDrivingScore = true
    @State private var showingFullscreenMap = false

    private let G = 9.80665

    private var gmax: Double { max(stats.peakNetAccel * 1.3, 0.5) }

    private var smoothnessScore: Int {
        let movingMin = max(1.0, stats.movingTimeSeconds / 60)
        let hard = Double(stats.hardAccelCount + stats.hardBrakingCount + stats.hardCorneringCount)
        let hardPerMin = hard / movingMin
        let v = 100 - 20 * hardPerMin - 30 * min(max(stats.rmsNet, 0), 1) - 8 * min(max(stats.peakNetJerk / 10, 0), 1)
        return Int(max(0, min(100, v)))
    }

    private var scoreLabel: String {
        switch smoothnessScore {
        case 85...: return "Excellent"
        case 70...: return "Good"
        case 50...: return "Fair"
        default:    return "Rough"
        }
    }

    // Full scatter when available; fall back to 4 axis-peak markers for stored sessions
    private var ggPoints: [GGPoint] {
        if !ggSamples.isEmpty { return ggSamples }
        guard stats.peakNetAccel > 0 else { return [] }
        return [
            GGPoint(lat: 0,               fwd: stats.peakForward,  isPeak: true),
            GGPoint(lat: 0,               fwd: stats.peakBraking,  isPeak: true),
            GGPoint(lat: stats.peakRight,  fwd: 0,                 isPeak: true),
            GGPoint(lat: stats.peakLeft,   fwd: 0,                 isPeak: true),
        ]
    }

    var body: some View {
        List {

            // Route map + speed legend
            if track.count >= 2 {
                Section {
                    VStack(spacing: 0) {
                        RouteMapView(track: track, peakEvents: peakEvents)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                                    .padding(7)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                    .padding(8)
                            }
                            .onTapGesture { showingFullscreenMap = true }
                        speedLegend.padding(.top, 10)
                    }
                }
                .sheet(isPresented: $showingFullscreenMap) {
                    NavigationStack {
                        RouteMapView(track: track, peakEvents: peakEvents)
                            .ignoresSafeArea(edges: .bottom)
                            .navigationTitle("Route")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("Done") { showingFullscreenMap = false }
                                }
                            }
                    }
                }
            }

            // Two dials: top speed + peak net g
            Section {
                HStack(spacing: 16) {
                    Spacer()
                    Dial(value: stats.maxSpeedMps * 3.6, max: 200,
                         unit: "km/h", label: "top speed",
                         size: 130, zone: .accentColor)
                    Spacer()
                    Dial(value: stats.peakNetAccel, max: 1,
                         unit: "g", label: "peak net",
                         size: 130, zone: .orange, decimals: 2)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // Speed + elevation charts
            if !track.isEmpty {
                let speeds = track.map { $0.speedMps * 3.6 }
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Speed over time").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "max %.0f km/h", speeds.max() ?? 0))
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Sparkline(data: speeds, color: .accentColor, showFill: true)
                    }
                    let alts = track.map { $0.altitudeM }
                    if alts.contains(where: { $0 != 0 }) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Elevation").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "+%.0f / −%.0f m", elevGain(alts), elevLoss(alts)))
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            Sparkline(data: alts, color: .green, showFill: true)
                        }
                    }
                }
            }

            // Overview stat cells
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    StatCell(label: "Duration",
                             value: formatDuration(stats.durationSeconds),
                             sub: "moving \(formatDuration(stats.movingTimeSeconds))")
                    StatCell(label: "Distance",
                             value: String(format: "%.1f", stats.totalDistanceM / 1000),
                             unit: "km")
                    StatCell(label: "Avg speed",
                             value: String(format: "%.0f", stats.avgSpeedMps * 3.6),
                             unit: "km/h",
                             sub: "moving \(Int(stats.avgMovingSpeedMps * 3.6))")
                    StatCell(label: "Stops",
                             value: "\(stats.stopCount)",
                             sub: "\(formatDuration(stats.stoppingTimeSeconds)) idle")
                    StatCell(label: "Hard events",
                             value: "\(stats.hardAccelCount + stats.hardBrakingCount + stats.hardCorneringCount)",
                             sub: "\(stats.hardAccelCount)A · \(stats.hardBrakingCount)B · \(stats.hardCorneringCount)C",
                             accent: true)
                    StatCell(label: "Surface", value: "\(stats.surfaceEventCount)", sub: "bumps")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            // Smoothness score
            if showDrivingScore {
                Section("Smoothness Score") {
                    HStack(spacing: 16) {
                        ScoreRing(value: smoothnessScore, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scoreLabel).font(.title3).fontWeight(.semibold)
                            Text("Hard events / min, sustained g-force, peak jerk.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }

            // g-g Envelope
            if !ggPoints.isEmpty {
                Section {
                    HStack { Spacer()
                        GGDiagram(points: ggPoints, gmax: gmax, size: 200, showEnvelope: true)
                    Spacer() }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("g-g Envelope").textCase(nil)
                        Spacer()
                        Text("peak markers").font(.caption2.monospaced()).foregroundStyle(.tertiary).textCase(nil)
                    }
                }
            }

            // Longitudinal
            Section {
                statRow("Peak acceleration",   fg(stats.peakForward, signed: true),  fm(stats.peakForward, signed: true))
                statRow("Peak braking",        fg(stats.peakBraking, signed: true),  fm(stats.peakBraking, signed: true))
                statRow("Average |a|",         fg(stats.avgLongitudinalAbs),         fm(stats.avgLongitudinalAbs))
                statRow("RMS",                 fg(stats.rmsForward),                 fm(stats.rmsForward))
                LabeledContent("Hard accel / brake",       value: "\(stats.hardAccelCount) / \(stats.hardBrakingCount)")
                LabeledContent("Avg jerk |longitudinal|",  value: String(format: "%.2f g/s", stats.avgJerkLongitudinalAbs))
                LabeledContent("Peak jerk fwd / brake",    value: String(format: "%.1f / %.1f g/s", stats.peakJerkForward, abs(stats.peakJerkBraking)))
            } header: {
                sectionHeader("Longitudinal", note: "m/s² · g")
            }

            // Lateral
            Section {
                statRow("Peak right",      fg(stats.peakRight, signed: true),  fm(stats.peakRight, signed: true))
                statRow("Peak left",       fg(stats.peakLeft, signed: true),   fm(stats.peakLeft, signed: true))
                statRow("Average |a|",     fg(stats.avgLateralAbs),            fm(stats.avgLateralAbs))
                statRow("RMS",             fg(stats.rmsLateral),               fm(stats.rmsLateral))
                LabeledContent("Hard cornering",      value: "\(stats.hardCorneringCount)")
                LabeledContent("Avg jerk |lateral|",  value: String(format: "%.2f g/s", stats.avgJerkLateralAbs))
                LabeledContent("Peak jerk R / L",     value: String(format: "%.1f / %.1f g/s", stats.peakJerkRight, abs(stats.peakJerkLeft)))
            } header: {
                sectionHeader("Lateral", note: "m/s² · g")
            }

            // Vertical & Net
            Section {
                LabeledContent("Surface events", value: "\(stats.surfaceEventCount)")
                LabeledContent("Peak up / down",  value: String(format: "%+.2f / %.2f g", stats.peakUp, stats.peakDown))
                statRow("Average |vertical|",    fg(stats.avgVerticalAbs),   fm(stats.avgVerticalAbs))
                statRow("RMS vertical",          fg(stats.rmsVertical),      fm(stats.rmsVertical))
                statRow("Net peak acceleration", fg(stats.peakNetAccel),     fm(stats.peakNetAccel))
                statRow("Net avg acceleration",  fg(stats.avgNetAccel),      fm(stats.avgNetAccel))
                statRow("Net RMS",               fg(stats.rmsNet),           fm(stats.rmsNet))
                LabeledContent("Net peak jerk",  value: String(format: "%.1f g/s  (%.1f m/s³)", stats.peakNetJerk, stats.peakNetJerk * G))
            } header: {
                sectionHeader("Vertical & Net", note: "m/s² · g")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String, _ si: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Text(si).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                Text(value).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).textCase(nil)
            Spacer()
            Text(note).font(.caption2.monospaced()).foregroundStyle(.tertiary).textCase(nil)
        }
    }

    // MARK: - Helpers

    private var speedLegend: some View {
        HStack(spacing: 8) {
            Text("0")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            LinearGradient(
                colors: [.red, .orange, .yellow, .green],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 6).clipShape(Capsule())
            Text(String(format: "%.0f km/h", stats.maxSpeedMps * 3.6))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func fg(_ v: Double, signed: Bool = false) -> String {
        signed ? String(format: "%+.2f g", v) : String(format: "%.2f g", v)
    }
    private func fm(_ v: Double, signed: Bool = false) -> String {
        signed ? String(format: "%+.2f m/s²", v * G) : String(format: "%.2f m/s²", v * G)
    }

    private func elevGain(_ alts: [Double]) -> Double {
        var g = 0.0
        for i in 1..<alts.count where alts[i] > alts[i - 1] { g += alts[i] - alts[i - 1] }
        return g
    }
    private func elevLoss(_ alts: [Double]) -> Double {
        var l = 0.0
        for i in 1..<alts.count where alts[i] < alts[i - 1] { l += alts[i - 1] - alts[i] }
        return l
    }
}
