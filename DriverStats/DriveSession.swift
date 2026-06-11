//
//  DriveSession.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import CoreLocation
import Foundation
import SwiftData

extension Int {
    var formattedBytes: String {
        if self < 1_024 { return "\(self) B" }
        if self < 1_024 * 1_024 { return String(format: "%.1f KB", Double(self) / 1_024) }
        return String(format: "%.1f MB", Double(self) / (1_024 * 1_024))
    }
}

@Model
final class DriveSession {

    // MARK: Time
    var startDate: Date = Date()
    var durationSeconds: Double = 0
    var stoppingTimeSeconds: Double = 0
    var stopCount: Int = 0

    // MARK: Distance
    var totalDistanceM: Double = 0

    // MARK: Speed
    var maxSpeedMps: Double = 0
    var avgSpeedMps: Double = 0
    var avgMovingSpeedMps: Double = 0

    // MARK: Longitudinal
    var peakForward: Double = 0
    var peakBraking: Double = 0
    var avgLongitudinalAbs: Double = 0
    var rmsForward: Double = 0
    var hardAccelCount: Int = 0
    var hardBrakingCount: Int = 0
    var peakJerkForward: Double = 0
    var peakJerkBraking: Double = 0
    var avgJerkLongitudinalAbs: Double = 0

    // MARK: Lateral
    var peakRight: Double = 0
    var peakLeft: Double = 0
    var avgLateralAbs: Double = 0
    var rmsLateral: Double = 0
    var hardCorneringCount: Int = 0
    var peakJerkRight: Double = 0
    var peakJerkLeft: Double = 0
    var avgJerkLateralAbs: Double = 0

    // MARK: Vertical
    var peakUp: Double = 0
    var peakDown: Double = 0
    var avgVerticalAbs: Double = 0
    var rmsVertical: Double = 0
    var peakJerkUp: Double = 0
    var peakJerkDown: Double = 0
    var avgJerkVerticalAbs: Double = 0

    // MARK: Net
    var peakNetAccel: Double = 0
    var avgNetAccel: Double = 0
    var rmsNet: Double = 0
    var peakNetJerk: Double = 0
    var avgNetJerk: Double = 0

    // MARK: Surface events
    var surfaceEventCount: Int = 0

    // MARK: Smoothness score (0–100)
    var smoothnessScore: Double = 0

    // MARK: Route (parallel arrays)
    var routeLatitudes: [Double] = []
    var routeLongitudes: [Double] = []
    var routeSpeeds: [Double] = []
    var routeAltitudes: [Double] = []

    // MARK: g-g scatter (parallel arrays — lateral, forward in g)
    var ggScatterLat: [Double] = []
    var ggScatterFwd: [Double] = []

    // MARK: Raw pre-smoothing 10 Hz samples (Float for compactness — used for recomputation)
    var rawFwd: [Float] = []
    var rawLat: [Float] = []
    var rawVert: [Float] = []

    // MARK: Peak event annotations (parallel arrays — type raw value, lat, lon, formatted string)
    var peakEventTypes: [Int] = []
    var peakEventLats: [Double] = []
    var peakEventLons: [Double] = []
    var peakEventFormatted: [String] = []

    init(result: SessionResult) {
        let s = result.stats
        startDate = s.startDate
        durationSeconds = s.durationSeconds
        stoppingTimeSeconds = s.stoppingTimeSeconds
        stopCount = s.stopCount
        totalDistanceM = s.totalDistanceM
        maxSpeedMps = s.maxSpeedMps
        avgSpeedMps = s.avgSpeedMps
        avgMovingSpeedMps = s.avgMovingSpeedMps
        peakForward = s.peakForward
        peakBraking = s.peakBraking
        avgLongitudinalAbs = s.avgLongitudinalAbs
        rmsForward = s.rmsForward
        hardAccelCount = s.hardAccelCount
        hardBrakingCount = s.hardBrakingCount
        peakJerkForward = s.peakJerkForward
        peakJerkBraking = s.peakJerkBraking
        avgJerkLongitudinalAbs = s.avgJerkLongitudinalAbs
        peakRight = s.peakRight
        peakLeft = s.peakLeft
        avgLateralAbs = s.avgLateralAbs
        rmsLateral = s.rmsLateral
        hardCorneringCount = s.hardCorneringCount
        peakJerkRight = s.peakJerkRight
        peakJerkLeft = s.peakJerkLeft
        avgJerkLateralAbs = s.avgJerkLateralAbs
        peakUp = s.peakUp
        peakDown = s.peakDown
        avgVerticalAbs = s.avgVerticalAbs
        rmsVertical = s.rmsVertical
        peakJerkUp = s.peakJerkUp
        peakJerkDown = s.peakJerkDown
        avgJerkVerticalAbs = s.avgJerkVerticalAbs
        peakNetAccel = s.peakNetAccel
        avgNetAccel = s.avgNetAccel
        rmsNet = s.rmsNet
        peakNetJerk = s.peakNetJerk
        avgNetJerk = s.avgNetJerk
        surfaceEventCount = s.surfaceEventCount
        let movingMin = max(1.0, s.movingTimeSeconds / 60)
        let hardEvents = Double(s.hardAccelCount + s.hardBrakingCount + s.hardCorneringCount)
        let hardPerMin = hardEvents / movingMin
        smoothnessScore = max(0, min(100, 100
            - 20 * hardPerMin
            - 30 * min(max(s.rmsNet, 0), 1)
            - 8  * min(max(s.peakNetJerk / 10, 0), 1)))
        routeLatitudes = result.track.map(\.coordinate.latitude)
        routeLongitudes = result.track.map(\.coordinate.longitude)
        routeSpeeds = result.track.map(\.speedMps)
        routeAltitudes = result.track.map(\.altitudeM)
        ggScatterLat = result.ggSamples.map(\.lat)
        ggScatterFwd = result.ggSamples.map(\.fwd)
        rawFwd = result.rawFwd
        rawLat = result.rawLat
        rawVert = result.rawVert
        peakEventTypes = result.peakEvents.map { $0.type.rawValue }
        peakEventLats = result.peakEvents.map { $0.coordinate.latitude }
        peakEventLons = result.peakEvents.map { $0.coordinate.longitude }
        peakEventFormatted = result.peakEvents.map { $0.formatted }
    }

    // MARK: Computed helpers

    var movingTimeSeconds: Double { max(0, durationSeconds - stoppingTimeSeconds) }

    var ggPointsStored: [GGPoint] {
        guard ggScatterLat.count == ggScatterFwd.count else { return [] }
        return zip(ggScatterLat, ggScatterFwd).map { GGPoint(lat: $0, fwd: $1) }
    }

    /// Approximate in-database size
    var estimatedSizeBytes: Int {
        let routeBytes = (routeLatitudes.count * 4 + peakEventTypes.count * 4) * 8
        let ggBytes = (ggScatterLat.count + ggScatterFwd.count) * 8
        let rawBytes = (rawFwd.count + rawLat.count + rawVert.count) * 4
        return routeBytes + ggBytes + rawBytes + 380
    }

    func recompute(hardThreshold: Double, surfaceThreshold: Double,
                   autoSmooth: Bool, smoothWindowSeconds: Double, suppressVertical: Bool) {
        guard rawFwd.count == rawLat.count, rawFwd.count == rawVert.count, !rawFwd.isEmpty else { return }

        let sampleRate = 10
        let smoothN = autoSmooth ? max(1, Int(smoothWindowSeconds * Double(sampleRate))) : 1
        var buf: [SIMD3<Double>] = []

        var haC = 0, hbC = 0, hcC = 0, seC = 0
        var inHA = false, inHB = false, inHC = false, inSE = false
        var ssqFwd = 0.0, ssqLat = 0.0, ssqVert = 0.0, ssqNet = 0.0
        var sumFwd = 0.0, sumLat = 0.0, sumVert = 0.0, sumNet = 0.0
        var pkFwd = 0.0, pkBrk = 0.0, pkRt = 0.0, pkLft = 0.0
        var pkUp = 0.0, pkDwn = 0.0, pkNet = 0.0
        var pkJFwd = 0.0, pkJBrk = 0.0, pkJRt = 0.0, pkJLft = 0.0, pkJNet = 0.0
        var prev: SIMD3<Double>? = nil
        let dt = 1.0 / Double(sampleRate)

        for i in 0..<rawFwd.count {
            let raw = SIMD3<Double>(Double(rawFwd[i]), Double(rawLat[i]), Double(rawVert[i]))
            buf.append(raw)
            if buf.count > smoothN { buf.removeFirst() }
            let sv = buf.reduce(.zero, +) / Double(buf.count)
            let f = sv.x, l = sv.y, v = suppressVertical ? 0.0 : sv.z
            let rawVz = raw.z
            let net = (f*f + l*l + v*v).squareRoot()

            ssqFwd += f*f; ssqLat += l*l; ssqVert += v*v; ssqNet += net*net
            sumFwd += abs(f); sumLat += abs(l); sumVert += abs(v); sumNet += net
            pkFwd = max(pkFwd, f); pkBrk = min(pkBrk, f)
            pkRt = max(pkRt, l); pkLft = min(pkLft, l)
            pkUp = max(pkUp, sv.z); pkDwn = min(pkDwn, sv.z)
            pkNet = max(pkNet, net)

            let nowHA = f > hardThreshold; if nowHA && !inHA { haC += 1 }; inHA = nowHA
            let nowHB = f < -hardThreshold; if nowHB && !inHB { hbC += 1 }; inHB = nowHB
            let nowHC = abs(l) > hardThreshold; if nowHC && !inHC { hcC += 1 }; inHC = nowHC
            let nowSE = abs(rawVz) > surfaceThreshold; if nowSE && !inSE { seC += 1 }; inSE = nowSE

            if let p = prev {
                let jF = (sv.x - p.x)/dt, jL = (sv.y - p.y)/dt, jV = (sv.z - p.z)/dt
                pkJFwd = max(pkJFwd, jF); pkJBrk = min(pkJBrk, jF)
                pkJRt = max(pkJRt, jL); pkJLft = min(pkJLft, jL)
                pkJNet = max(pkJNet, (jF*jF + jL*jL + jV*jV).squareRoot())
            }
            prev = sv
        }

        let n = Double(rawFwd.count)
        hardAccelCount = haC; hardBrakingCount = hbC; hardCorneringCount = hcC; surfaceEventCount = seC
        peakForward = pkFwd; peakBraking = pkBrk; peakRight = pkRt; peakLeft = pkLft
        peakUp = pkUp; peakDown = pkDwn; peakNetAccel = pkNet
        rmsForward = (ssqFwd/n).squareRoot(); rmsLateral = (ssqLat/n).squareRoot()
        rmsVertical = (ssqVert/n).squareRoot(); rmsNet = (ssqNet/n).squareRoot()
        avgLongitudinalAbs = sumFwd/n; avgLateralAbs = sumLat/n
        avgVerticalAbs = sumVert/n; avgNetAccel = sumNet/n
        peakJerkForward = pkJFwd; peakJerkBraking = pkJBrk
        peakJerkRight = pkJRt; peakJerkLeft = pkJLft; peakNetJerk = pkJNet

        let movingMin = max(1.0, movingTimeSeconds / 60)
        let hard = Double(hardAccelCount + hardBrakingCount + hardCorneringCount)
        smoothnessScore = max(0, min(100, 100
            - 20 * (hard / movingMin)
            - 30 * min(max(rmsNet, 0), 1)
            - 8  * min(max(peakNetJerk / 10, 0), 1)))
    }

    var routePoints: [RoutePoint] {
        let hasAlt = routeAltitudes.count == routeLatitudes.count
        let alts = hasAlt ? routeAltitudes : Array(repeating: 0.0, count: routeLatitudes.count)
        return zip(zip(routeLatitudes, routeLongitudes), zip(routeSpeeds, alts)).map { coords, sa in
            RoutePoint(
                coordinate: CLLocationCoordinate2D(latitude: coords.0, longitude: coords.1),
                speedMps: sa.0,
                altitudeM: sa.1
            )
        }
    }

    var speedsKph: [Double] { routeSpeeds.map { $0 * 3.6 } }

    var altitudesM: [Double] { routeAltitudes }

    var peakEventsRestored: [PeakEvent] {
        zip(zip(peakEventTypes, zip(peakEventLats, peakEventLons)), peakEventFormatted)
            .compactMap { typeCoord, formatted in
                let (typeInt, (lat, lon)) = typeCoord
                guard let type = PeakEventType(rawValue: typeInt) else { return nil }
                return PeakEvent(
                    type: type,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    formatted: formatted
                )
            }
    }
}
