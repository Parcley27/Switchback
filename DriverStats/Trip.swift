//
//  Trip.swift
//  DriverStats
//

import CoreLocation
import Foundation
import SwiftData

@Model
final class Trip {
    var name: String = "Trip"
    var createdDate: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \DriveSession.trip)
    var sessions: [DriveSession] = []

    init(name: String = "Trip") {
        self.name = name
        self.createdDate = Date()
    }

    var orderedSessions: [DriveSession] {
        sessions.sorted { $0.startDate < $1.startDate }
    }

    var totalDistanceM: Double {
        sessions.reduce(0) { $0 + $1.totalDistanceM }
    }

    // Wall-clock span from first session start to last session end
    var totalSpanSeconds: Double {
        let ordered = orderedSessions
        guard let first = ordered.first, let last = ordered.last else { return 0 }
        return max(0, last.startDate.addingTimeInterval(last.durationSeconds).timeIntervalSince(first.startDate))
    }

    // Sum of actual recorded driving time across all sessions
    var totalDrivingSeconds: Double {
        sessions.reduce(0) { $0 + $1.durationSeconds }
    }

    var totalStops: Int {
        sessions.reduce(0) { $0 + $1.stopCount }
    }

    var startDate: Date? { orderedSessions.first?.startDate }

    var endDate: Date? {
        guard let last = orderedSessions.last else { return nil }
        return last.startDate.addingTimeInterval(last.durationSeconds)
    }

    var driveCount: Int { sessions.count }

    // Real drives (excludes auto-generated connectors) for stats purposes
    var scoredSessions: [DriveSession] {
        sessions.filter { $0.driveMode.receivesScore }
    }

    var avgSmoothnessScore: Double {
        let scored = scoredSessions
        guard !scored.isEmpty else { return 0 }
        return scored.reduce(0) { $0 + $1.smoothnessScore } / Double(scored.count)
    }

    /// Returns gaps between each consecutive pair of ordered sessions.
    func sessionGaps() -> [(first: DriveSession, second: DriveSession, gapSeconds: Double, gapMeters: Double)] {
        let ordered = orderedSessions
        guard ordered.count >= 2 else { return [] }
        var result: [(DriveSession, DriveSession, Double, Double)] = []
        for i in 0..<(ordered.count - 1) {
            let a = ordered[i]
            let b = ordered[i + 1]
            let endOfA = a.startDate.addingTimeInterval(a.durationSeconds)
            let gapSecs = max(0, b.startDate.timeIntervalSince(endOfA))
            let gapM: Double
            if let aLat = a.routeLatitudes.last, let aLon = a.routeLongitudes.last,
               let bLat = b.routeLatitudes.first, let bLon = b.routeLongitudes.first {
                let locA = CLLocation(latitude: aLat, longitude: aLon)
                let locB = CLLocation(latitude: bLat, longitude: bLon)
                gapM = locA.distance(from: locB)
            } else {
                gapM = 0
            }
            result.append((a, b, gapSecs, gapM))
        }
        return result
    }
}
