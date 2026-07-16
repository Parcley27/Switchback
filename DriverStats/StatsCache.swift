//
//  StatsCache.swift
//  DriverStats
//

import Foundation

// All aggregate statistics across every drive session, Codable for JSON disk persistence.
struct CachedStats: Codable {
    let totalDurationSeconds: Double
    let totalMovingTimeSeconds: Double
    let totalStoppingTimeSeconds: Double
    let avgDurationSeconds: Double
    let avgMovingTimeSeconds: Double
    let totalStops: Int
    let totalDistanceM: Double
    let longestDriveKm: Double
    let avgDistanceKm: Double
    let avgOverallSpeedMps: Double
    let avgMovingSpeedMps: Double
    let topSpeedMps: Double
    let avgScore: Double
    let bestScore: Double
    let worstScore: Double
    let totalHardAccel: Int
    let totalHardBraking: Int
    let totalHardCornering: Int
    let totalSurfaceEvents: Int
    let bestPeakNet: Double
    let avgPeakNet: Double
    let bestPeakForward: Double
    let bestPeakBraking: Double
    let bestPeakCornering: Double
    let avgRmsNet: Double
    let trendScores: [Int]

    static func build(from sessions: [DriveSession]) -> CachedStats {
        let n = sessions.count
        let totalDist = sessions.reduce(0.0) { $0 + $1.totalDistanceM }
        let totalDur = sessions.reduce(0.0) { $0 + $1.durationSeconds }
        let totalMoving = sessions.reduce(0.0) { $0 + $1.movingTimeSeconds }
        let totalStopping = sessions.reduce(0.0) { $0 + $1.stoppingTimeSeconds }
        let totalStops = sessions.reduce(0) { $0 + $1.stopCount }
        let scores: [Double] = sessions.map { $0.smoothnessScore }

        return CachedStats(
            totalDurationSeconds: totalDur,
            totalMovingTimeSeconds: totalMoving,
            totalStoppingTimeSeconds: totalStopping,
            avgDurationSeconds: n == 0 ? 0 : totalDur / Double(n),
            avgMovingTimeSeconds: n == 0 ? 0 : totalMoving / Double(n),
            totalStops: totalStops,
            totalDistanceM: totalDist,
            longestDriveKm: sessions.map { $0.totalDistanceM / 1000 }.max() ?? 0,
            avgDistanceKm: n == 0 ? 0 : totalDist / 1000 / Double(n),
            avgOverallSpeedMps: n == 0 ? 0 : sessions.reduce(0.0) { $0 + $1.avgSpeedMps } / Double(n),
            avgMovingSpeedMps: n == 0 ? 0 : sessions.reduce(0.0) { $0 + $1.avgMovingSpeedMps } / Double(n),
            topSpeedMps: sessions.map { $0.maxSpeedMps }.max() ?? 0,
            avgScore: scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count),
            bestScore: scores.max() ?? 0,
            worstScore: scores.min() ?? 0,
            totalHardAccel: sessions.reduce(0) { $0 + $1.hardAccelCount },
            totalHardBraking: sessions.reduce(0) { $0 + $1.hardBrakingCount },
            totalHardCornering: sessions.reduce(0) { $0 + $1.hardCorneringCount },
            totalSurfaceEvents: sessions.reduce(0) { $0 + $1.surfaceEventCount },
            bestPeakNet: sessions.map { $0.peakNetAccel }.max() ?? 0,
            avgPeakNet: n == 0 ? 0 : sessions.reduce(0.0) { $0 + $1.peakNetAccel } / Double(n),
            bestPeakForward: sessions.map { $0.peakForward }.max() ?? 0,
            bestPeakBraking: sessions.map { abs($0.peakBraking) }.max() ?? 0,
            bestPeakCornering: sessions.map { max($0.peakRight, abs($0.peakLeft)) }.max() ?? 0,
            avgRmsNet: n == 0 ? 0 : sessions.reduce(0.0) { $0 + $1.rmsNet } / Double(n),
            trendScores: Array(sessions.prefix(12).reversed().map { Int($0.smoothnessScore) })
        )
    }
}

final class StatsCache {
    static let shared = StatsCache()
    private init() {}

    private let fileURL: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("aggregateStats.json")
    }()

    private var memKey = ""
    private var memStats: CachedStats? = nil

    static func key(for sessions: [DriveSession]) -> String {
        let latest = sessions.first?.startDate.timeIntervalSinceReferenceDate ?? 0
        return "v1:\(sessions.count):\(Int(latest))"
    }

    func load(key: String) -> CachedStats? {
        if memKey == key, let s = memStats { return s }
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.key == key else { return nil }
        memKey = key
        memStats = envelope.stats
        return envelope.stats
    }

    func save(_ stats: CachedStats, key: String) {
        memKey = key
        memStats = stats
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(Envelope(key: key, stats: stats)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        memKey = ""
        memStats = nil
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    var diskSizeBytes: Int {
        guard let url = fileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return size
    }

    private struct Envelope: Codable {
        let key: String
        let stats: CachedStats
    }
}
