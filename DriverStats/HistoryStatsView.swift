//
//  HistoryStatsView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import SwiftUI

struct HistoryStatsView: View {
    let sessions: [DriveSession]

    private let G = 9.80665

    var body: some View {
        List {

            Section("Sessions & Time") {
                LabeledContent("Total sessions",       value: "\(sessions.count)")
                LabeledContent("Total drive time",     value: fmt(totalDuration))
                LabeledContent("Total moving time",    value: fmt(totalMovingTime))
                LabeledContent("Total stopped time",   value: fmt(totalStoppingTime))
                LabeledContent("Avg session length",   value: formatDuration(avgDuration))
                LabeledContent("Avg moving time",      value: formatDuration(avgMovingTime))
                LabeledContent("Total stops",          value: "\(totalStops)")
                LabeledContent("Avg stops / drive",    value: String(format: "%.1f", avgStopsPerDrive))
            }

            Section("Distance & Speed") {
                LabeledContent("Total distance",       value: String(format: "%.1f km", totalKm))
                LabeledContent("Avg session distance", value: String(format: "%.1f km", avgDistanceKm))
                LabeledContent("Longest drive",        value: String(format: "%.1f km", longestDriveKm))
                LabeledContent("Avg overall speed",    value: String(format: "%.1f km/h", avgOverallSpeedKph))
                LabeledContent("Avg moving speed",     value: String(format: "%.1f km/h", avgMovingSpeedKph))
                LabeledContent("All-time top speed",   value: String(format: "%.1f km/h", topSpeedKph))
            }

            Section("Smoothness & Events") {
                LabeledContent("Avg smoothness score", value: String(format: "%.0f / 100", avgScore))
                LabeledContent("Best session score",   value: String(format: "%.0f", bestScore))
                LabeledContent("Worst session score",  value: String(format: "%.0f", worstScore))
                LabeledContent("Total hard events",    value: "\(totalHardEvents)")
                LabeledContent("Accel / brake / corner",
                               value: "\(totalHardAccel) / \(totalHardBraking) / \(totalHardCornering)")
                LabeledContent("Avg hard events / drive", value: String(format: "%.1f", avgHardPerDrive))
                LabeledContent("Total surface events", value: "\(totalSurfaceEvents)")
                LabeledContent("Avg surface / drive",  value: String(format: "%.1f", avgSurfacePerDrive))
            }

            Section("Acceleration") {
                LabeledContent("Best peak net g",
                               value: String(format: "%.2f g  (%.1f m/s²)", bestPeakNet, bestPeakNet * G))
                LabeledContent("Avg peak net g",       value: String(format: "%.2f g", avgPeakNet))
                LabeledContent("Best peak forward",    value: String(format: "%.2f g", bestPeakForward))
                LabeledContent("Best peak braking",    value: String(format: "%.2f g", bestPeakBraking))
                LabeledContent("Best peak cornering",  value: String(format: "%.2f g", bestPeakCornering))
                LabeledContent("Avg RMS net",          value: String(format: "%.3f g", avgRmsNet))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Full Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Aggregates

    private var totalDuration: Double     { sessions.reduce(0) { $0 + $1.durationSeconds } }
    private var totalMovingTime: Double   { sessions.reduce(0) { $0 + $1.movingTimeSeconds } }
    private var totalStoppingTime: Double { sessions.reduce(0) { $0 + $1.stoppingTimeSeconds } }
    private var avgDuration: Double       { sessions.isEmpty ? 0 : totalDuration / Double(sessions.count) }
    private var avgMovingTime: Double     { sessions.isEmpty ? 0 : totalMovingTime / Double(sessions.count) }
    private var totalStops: Int           { sessions.reduce(0) { $0 + $1.stopCount } }
    private var avgStopsPerDrive: Double  { sessions.isEmpty ? 0 : Double(totalStops) / Double(sessions.count) }

    private var totalKm: Double           { sessions.reduce(0) { $0 + $1.totalDistanceM } / 1000 }
    private var avgDistanceKm: Double     { sessions.isEmpty ? 0 : totalKm / Double(sessions.count) }
    private var longestDriveKm: Double    { sessions.map { $0.totalDistanceM / 1000 }.max() ?? 0 }
    private var avgOverallSpeedKph: Double  { sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.avgSpeedMps } / Double(sessions.count) * 3.6 }
    private var avgMovingSpeedKph: Double   { sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.avgMovingSpeedMps } / Double(sessions.count) * 3.6 }
    private var topSpeedKph: Double       { sessions.map { $0.maxSpeedMps * 3.6 }.max() ?? 0 }

    private func score(_ s: DriveSession) -> Double {
        let m = max(1.0, s.movingTimeSeconds / 60)
        let h = Double(s.hardAccelCount + s.hardBrakingCount + s.hardCorneringCount)
        return max(0, min(100, 100 - 20*(h/m) - 30*min(max(s.rmsNet,0),1) - 8*min(max(s.peakNetJerk/10,0),1)))
    }

    private var allScores: [Double]       { sessions.map { score($0) } }
    private var avgScore: Double          { allScores.isEmpty ? 0 : allScores.reduce(0,+) / Double(allScores.count) }
    private var bestScore: Double         { allScores.max() ?? 0 }
    private var worstScore: Double        { allScores.min() ?? 0 }

    private var totalHardAccel: Int       { sessions.reduce(0) { $0 + $1.hardAccelCount } }
    private var totalHardBraking: Int     { sessions.reduce(0) { $0 + $1.hardBrakingCount } }
    private var totalHardCornering: Int   { sessions.reduce(0) { $0 + $1.hardCorneringCount } }
    private var totalHardEvents: Int      { totalHardAccel + totalHardBraking + totalHardCornering }
    private var avgHardPerDrive: Double   { sessions.isEmpty ? 0 : Double(totalHardEvents) / Double(sessions.count) }
    private var totalSurfaceEvents: Int   { sessions.reduce(0) { $0 + $1.surfaceEventCount } }
    private var avgSurfacePerDrive: Double { sessions.isEmpty ? 0 : Double(totalSurfaceEvents) / Double(sessions.count) }

    private var bestPeakNet: Double       { sessions.map { $0.peakNetAccel }.max() ?? 0 }
    private var avgPeakNet: Double        { sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.peakNetAccel } / Double(sessions.count) }
    private var bestPeakForward: Double   { sessions.map { $0.peakForward }.max() ?? 0 }
    private var bestPeakBraking: Double   { sessions.map { abs($0.peakBraking) }.max() ?? 0 }
    private var bestPeakCornering: Double { sessions.map { max($0.peakRight, abs($0.peakLeft)) }.max() ?? 0 }
    private var avgRmsNet: Double         { sessions.isEmpty ? 0 : sessions.reduce(0) { $0 + $1.rmsNet } / Double(sessions.count) }

    private func fmt(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let d = m / (24*60), h = (m % (24*60)) / 60, mn = m % 60
        if d > 0  { return "\(d)d \(h)h" }
        if h > 0  { return "\(h)h \(mn)m" }
        return "\(mn)m"
    }
}
