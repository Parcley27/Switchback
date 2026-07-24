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

    private var stats: CachedStats {
        let key = StatsCache.key(for: sessions)
        if let cached = StatsCache.shared.load(key: key) { return cached }
        let built = CachedStats.build(from: sessions)
        StatsCache.shared.save(built, key: key)
        return built
    }

    var body: some View {
        let n = sessions.count
        let totalHardEvents = stats.totalHardAccel + stats.totalHardBraking + stats.totalHardCornering
        List {
            Section("Sessions & Time") {
                LabeledContent("Total sessions",       value: "\(n)")
                LabeledContent("Days with drives",     value: "\(stats.totalDaysWithDrives)")
                LabeledContent("Avg drives / week",    value: String(format: "%.1f", stats.avgDrivesPerWeek))
                LabeledContent("Total drive time",     value: fmt(stats.totalDurationSeconds))
                LabeledContent("Total moving time",    value: fmt(stats.totalMovingTimeSeconds))
                LabeledContent("Total stopped time",   value: fmt(stats.totalStoppingTimeSeconds))
                LabeledContent("Avg session length",   value: formatDuration(stats.avgDurationSeconds))
                LabeledContent("Avg moving time",      value: formatDuration(stats.avgMovingTimeSeconds))
                LabeledContent("Total stops",          value: "\(stats.totalStops)")
                LabeledContent("Avg stops / drive",    value: String(format: "%.1f", n == 0 ? 0 : Double(stats.totalStops) / Double(n)))
            }

            Section("Distance & Speed") {
                LabeledContent("Total distance",       value: String(format: "%.1f km", stats.totalDistanceM / 1000))
                LabeledContent("Avg session distance", value: String(format: "%.1f km", stats.avgDistanceKm))
                LabeledContent("Longest drive",        value: String(format: "%.1f km", stats.longestDriveKm))
                if stats.shortestDriveKm > 0 {
                    LabeledContent("Shortest drive",   value: String(format: "%.1f km", stats.shortestDriveKm))
                }
                LabeledContent("Avg overall speed",    value: String(format: "%.1f km/h", stats.avgOverallSpeedMps * 3.6))
                LabeledContent("Avg moving speed",     value: String(format: "%.1f km/h", stats.avgMovingSpeedMps * 3.6))
                LabeledContent("All-time top speed",   value: String(format: "%.1f km/h", stats.topSpeedMps * 3.6))
            }

            Section("Smoothness & Events") {
                LabeledContent("Avg smoothness score", value: String(format: "%.0f / 100", stats.avgScore))
                LabeledContent("Best session score",   value: String(format: "%.0f", stats.bestScore))
                LabeledContent("Worst session score",  value: String(format: "%.0f", stats.worstScore))
                LabeledContent("Total hard events",    value: "\(totalHardEvents)")
                LabeledContent("Accel / brake / corner",
                               value: "\(stats.totalHardAccel) / \(stats.totalHardBraking) / \(stats.totalHardCornering)")
                LabeledContent("Avg hard events / drive", value: String(format: "%.1f", n == 0 ? 0 : Double(totalHardEvents) / Double(n)))
                LabeledContent("Total surface events", value: "\(stats.totalSurfaceEvents)")
                LabeledContent("Avg surface / drive",  value: String(format: "%.1f", n == 0 ? 0 : Double(stats.totalSurfaceEvents) / Double(n)))
            }

            Section("Acceleration") {
                LabeledContent("Best peak net g",
                               value: String(format: "%.2f g  (%.1f m/s²)", stats.bestPeakNet, stats.bestPeakNet * G))
                LabeledContent("Avg peak net g",       value: String(format: "%.2f g", stats.avgPeakNet))
                LabeledContent("Best peak forward",    value: String(format: "%.2f g", stats.bestPeakForward))
                LabeledContent("Best peak braking",    value: String(format: "%.2f g", stats.bestPeakBraking))
                LabeledContent("Best peak cornering",  value: String(format: "%.2f g", stats.bestPeakCornering))
                LabeledContent("Avg RMS net",          value: String(format: "%.3f g", stats.avgRmsNet))
                LabeledContent("Best peak jerk",       value: String(format: "%.2f g/s", stats.bestPeakJerk))
                LabeledContent("Avg peak jerk",        value: String(format: "%.2f g/s", stats.avgPeakJerk))
            }

            Section("Drive Modes") {
                LabeledContent("Normal",               value: "\(stats.normalSessionCount)")
                LabeledContent("Off-road",             value: "\(stats.offroadSessionCount)")
                LabeledContent("Racing",               value: "\(stats.racingSessionCount)")
                if stats.totalLapSplits > 0 {
                    LabeledContent("Total lap splits", value: "\(stats.totalLapSplits)")
                }
            }

            Section("Data") {
                LabeledContent("Estimated size",       value: stats.totalRawBytes.formattedBytes)
                LabeledContent("Avg per drive",        value: (n == 0 ? 0 : stats.totalRawBytes / n).formattedBytes)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Full Statistics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fmt(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let d = m / (24*60), h = (m % (24*60)) / 60, mn = m % 60
        if d > 0  { return "\(d)d \(h)h" }
        if h > 0  { return "\(h)h \(mn)m" }
        return "\(mn)m"
    }
}
