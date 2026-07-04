//
//  AccelerationTypes.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import CoreLocation
import Foundation

// MARK: - Motion types

struct AccelerationComponents {
    /// Positive = accelerating forward, negative = braking
    let forward: Double
    /// Positive = turning right (rightward centripetal force), negative = turning left
    let lateral: Double
    /// Positive = upward bump, negative = downward dip
    let vertical: Double
    let timestamp: Date
}

/// One data point in the rolling graph buffer, recorded at ~10 Hz
struct AccelerationSample: Identifiable {
    let id: Int
    /// Seconds since recording started
    let elapsedSeconds: Double
    let forward: Double
    let lateral: Double
    let vertical: Double
}

// MARK: - Peak event types

enum PeakEventType: Int {
    case maxSpeed = 0, peakAccel = 1, peakBraking = 2, peakRight = 3, peakLeft = 4, surface = 5

    var title: String {
        switch self {
        case .maxSpeed:    return "Top Speed"
        case .peakAccel:   return "Peak Acceleration"
        case .peakBraking: return "Peak Braking"
        case .peakRight:   return "Peak Right Turn"
        case .peakLeft:    return "Peak Left Turn"
        case .surface:     return "Road Surface"
        }
    }

    var sfSymbol: String {
        switch self {
        case .maxSpeed:    return "flag.checkered"
        case .peakAccel:   return "bolt.fill"
        case .peakBraking: return "exclamationmark.triangle.fill"
        case .peakRight:   return "arrow.turn.up.right"
        case .peakLeft:    return "arrow.turn.up.left"
        case .surface:     return "car.rear.and.collision.road.lane"
        }
    }
}

struct PeakEvent {
    let type: PeakEventType
    let coordinate: CLLocationCoordinate2D
    let formatted: String
}
