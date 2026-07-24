//
//  LocationManager.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import CoreLocation
import Combine
import Foundation

struct RoutePoint {
    let coordinate: CLLocationCoordinate2D
    let speedMps: Double
    let altitudeM: Double
}

@MainActor
class LocationManager: NSObject, ObservableObject {

    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var trackPoints: [RoutePoint] = []
    /// m/s, negative means no valid fix
    @Published private(set) var speed: Double = -1
    /// Degrees clockwise from true north, negative means no valid fix
    @Published private(set) var course: Double = -1
    /// Meters, negative means no valid fix
    @Published private(set) var horizontalAccuracy: Double = -1
    @Published private(set) var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
    @Published private(set) var altitudeM: Double = 0
    @Published private(set) var lastUpdate: Date?

    // MARK: - Lap tracking

    /// Individual lap durations in seconds, one entry per completed lap.
    private(set) var lapSplits: [Double] = []
    private var lapTrackStartDate: Date = Date()
    private var lastLapCompletionDate: Date? = nil
    /// Prevents false lap detections while the driver is still at the start area.
    /// Set to true once the driver moves outside lapRadiusM; reset after each lap.
    private var hasExitedLapZone: Bool = false

    /// Minimum speed (m/s) below which GPS course is considered unreliable
    static let minReliableSpeedMps: Double = 2.0
    /// Maximum horizontal accuracy (m) above which the fix is considered too poor to use
    static let maxReliableAccuracyM: Double = 50.0
    /// Radius around the recording start point that counts as lap completion (metres)
    static let lapRadiusM: Double = 10
    /// Minimum seconds between consecutive lap detections — guards against multiple
    /// triggers while passing through the start zone on short circuits
    static let lapMinIntervalS: Double = 20

    /// True when location is authorized and the horizontal accuracy is good enough to use
    var hasValidFix: Bool {
        (authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways) &&
        horizontalAccuracy >= 0 &&
        horizontalAccuracy < Self.maxReliableAccuracyM
    }

    var isCourseReliable: Bool {
        course >= 0 &&
        speed >= Self.minReliableSpeedMps &&
        horizontalAccuracy >= 0 &&
        horizontalAccuracy < Self.maxReliableAccuracyM
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = manager.authorizationStatus
    }

    func startTrack() {
        trackPoints = []
        lapSplits = []
        lapTrackStartDate = Date()
        lastLapCompletionDate = nil
        hasExitedLapZone = false
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func stopTrack() {
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestPermissionAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Request "Always" so GPS and CoreMotion continue with the screen off.
            // Requires NSLocationAlwaysAndWhenInUseUsageDescription in Info.plist
            // and "Location updates" under target Signing & Capabilities > Background Modes.
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startLocationUpdates()
        default:
            break
        }
    }

    private func startLocationUpdates() {
        manager.startUpdatingLocation()
    }

    private func checkLapCompletion(coordinate: CLLocationCoordinate2D) {
        guard trackPoints.count > 1 else { return }
        let origin = trackPoints[0].coordinate
        let dist = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))

        if dist > Self.lapRadiusM {
            hasExitedLapZone = true
        } else if hasExitedLapZone {
            let now = Date()
            let lapStart = lastLapCompletionDate ?? lapTrackStartDate
            let elapsed = now.timeIntervalSince(lapStart)
            if elapsed >= Self.lapMinIntervalS {
                lapSplits.append(elapsed)
                lastLapCompletionDate = now
                hasExitedLapZone = false
            }
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.speed = loc.speed
            self.course = loc.course
            self.horizontalAccuracy = loc.horizontalAccuracy
            self.coordinate = loc.coordinate
            self.altitudeM = loc.altitude
            self.lastUpdate = Date()
            if loc.horizontalAccuracy >= 0 {
                self.trackPoints.append(RoutePoint(
                    coordinate: loc.coordinate,
                    speedMps: max(0, loc.speed),
                    altitudeM: loc.altitude
                ))
                self.checkLapCompletion(coordinate: loc.coordinate)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                self.startLocationUpdates()
            }
        }
    }
}
