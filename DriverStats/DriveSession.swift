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

    // MARK: Place names (reverse-geocoded after save)
    var startPlaceName: String?
    var endPlaceName: String?

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

    // MARK: Lap splits (seconds per lap, empty when no circuit was detected)
    var lapSplitSeconds: [Double] = []

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
        lapSplitSeconds = result.lapSplits
    }

    // MARK: - Merge initializer

    /// Creates a combined session from two sessions recorded on the same trip.
    /// Call recompute() immediately after inserting into the model context to derive
    /// accurate RMS, peak, and smoothness values from the concatenated raw arrays.
    init(merging a: DriveSession, with b: DriveSession) {
        let first  = a.startDate <= b.startDate ? a : b
        let second = a.startDate <= b.startDate ? b : a

        let firstEnd  = first.startDate.addingTimeInterval(first.durationSeconds)
        let gapSecs   = max(0, second.startDate.timeIntervalSince(firstEnd))
        let totalDist = first.totalDistanceM + second.totalDistanceM
        let totalDur  = second.startDate.timeIntervalSince(first.startDate) + second.durationSeconds
        let totalStop = first.stoppingTimeSeconds + second.stoppingTimeSeconds + gapSecs
        let movingDur = max(1, totalDur - totalStop)

        // Time
        startDate           = first.startDate
        durationSeconds     = totalDur
        stoppingTimeSeconds = totalStop
        stopCount           = first.stopCount + second.stopCount + 1

        // Distance & speed
        totalDistanceM      = totalDist
        maxSpeedMps         = max(first.maxSpeedMps, second.maxSpeedMps)
        avgSpeedMps         = totalDur > 0 ? totalDist / totalDur : 0
        avgMovingSpeedMps   = totalDist / movingDur

        // Route arrays
        routeLatitudes      = first.routeLatitudes  + second.routeLatitudes
        routeLongitudes     = first.routeLongitudes + second.routeLongitudes
        routeSpeeds         = first.routeSpeeds     + second.routeSpeeds
        routeAltitudes      = first.routeAltitudes  + second.routeAltitudes

        // Place names
        startPlaceName      = first.startPlaceName
        endPlaceName        = second.endPlaceName

        // G-G scatter
        ggScatterLat        = first.ggScatterLat + second.ggScatterLat
        ggScatterFwd        = first.ggScatterFwd + second.ggScatterFwd

        // Raw sensor samples (recompute() derives all acceleration stats from these)
        rawFwd              = first.rawFwd  + second.rawFwd
        rawLat              = first.rawLat  + second.rawLat
        rawVert             = first.rawVert + second.rawVert

        // Peak event annotations
        peakEventTypes      = first.peakEventTypes     + second.peakEventTypes
        peakEventLats       = first.peakEventLats      + second.peakEventLats
        peakEventLons       = first.peakEventLons      + second.peakEventLons
        peakEventFormatted  = first.peakEventFormatted + second.peakEventFormatted

        // Lap splits (per-lap durations — concatenate directly)
        lapSplitSeconds     = first.lapSplitSeconds + second.lapSplitSeconds

        // Seed peak stats — recompute() will replace the ones it covers
        peakForward     = max(first.peakForward,  second.peakForward)
        peakBraking     = min(first.peakBraking,  second.peakBraking)
        peakRight       = max(first.peakRight,    second.peakRight)
        peakLeft        = min(first.peakLeft,     second.peakLeft)
        peakUp          = max(first.peakUp,       second.peakUp)
        peakDown        = min(first.peakDown,     second.peakDown)
        peakNetAccel    = max(first.peakNetAccel, second.peakNetAccel)
        peakJerkForward = max(first.peakJerkForward,  second.peakJerkForward)
        peakJerkBraking = min(first.peakJerkBraking,  second.peakJerkBraking)
        peakJerkRight   = max(first.peakJerkRight,    second.peakJerkRight)
        peakJerkLeft    = min(first.peakJerkLeft,     second.peakJerkLeft)
        peakJerkUp      = max(first.peakJerkUp,       second.peakJerkUp)
        peakJerkDown    = min(first.peakJerkDown,     second.peakJerkDown)
        peakNetJerk     = max(first.peakNetJerk,      second.peakNetJerk)

        // Weighted averages by sample count — recompute() replaces the ones it covers
        let n1 = Double(max(1, first.rawFwd.count))
        let n2 = Double(max(1, second.rawFwd.count))
        let nT = n1 + n2
        avgLongitudinalAbs     = (first.avgLongitudinalAbs     * n1 + second.avgLongitudinalAbs     * n2) / nT
        avgLateralAbs          = (first.avgLateralAbs          * n1 + second.avgLateralAbs          * n2) / nT
        avgVerticalAbs         = (first.avgVerticalAbs         * n1 + second.avgVerticalAbs         * n2) / nT
        avgNetAccel            = (first.avgNetAccel            * n1 + second.avgNetAccel            * n2) / nT
        rmsForward             = (first.rmsForward             * n1 + second.rmsForward             * n2) / nT
        rmsLateral             = (first.rmsLateral             * n1 + second.rmsLateral             * n2) / nT
        rmsVertical            = (first.rmsVertical            * n1 + second.rmsVertical            * n2) / nT
        rmsNet                 = (first.rmsNet                 * n1 + second.rmsNet                 * n2) / nT
        avgJerkLongitudinalAbs = (first.avgJerkLongitudinalAbs * n1 + second.avgJerkLongitudinalAbs * n2) / nT
        avgJerkLateralAbs      = (first.avgJerkLateralAbs      * n1 + second.avgJerkLateralAbs      * n2) / nT
        avgJerkVerticalAbs     = (first.avgJerkVerticalAbs     * n1 + second.avgJerkVerticalAbs     * n2) / nT
        avgNetJerk             = (first.avgNetJerk             * n1 + second.avgNetJerk             * n2) / nT

        hardAccelCount     = first.hardAccelCount     + second.hardAccelCount
        hardBrakingCount   = first.hardBrakingCount   + second.hardBrakingCount
        hardCorneringCount = first.hardCorneringCount + second.hardCorneringCount
        surfaceEventCount  = first.surfaceEventCount  + second.surfaceEventCount

        smoothnessScore    = 0  // replaced by recompute()
    }

    // MARK: - Split initializer

    /// Creates one half of a session split at `routeIndex`. Pass `isFirst: true` for
    /// the earlier portion, `isFirst: false` for the later portion. Call `recompute(…)`
    /// immediately after inserting into the model context to derive accurate stats.
    init(splitting original: DriveSession, at routeIndex: Int, isFirst: Bool) {
        let routeCount = max(1, original.routeLatitudes.count)
        let N          = max(1, min(routeIndex, routeCount - 1))
        let rawCount   = original.rawFwd.count
        let rawN       = rawCount > 0 ? Int(Double(N) / Double(routeCount) * Double(rawCount)) : 0
        let frac       = Double(N) / Double(routeCount)
        let dt         = original.durationSeconds / Double(routeCount)

        if isFirst {
            let speeds      = Array(original.routeSpeeds.prefix(N))
            let dur         = original.durationSeconds * frac
            let dist        = speeds.reduce(0.0, +) * dt
            let stoppedDur  = Double(speeds.filter { $0 < 0.5 }.count) * dt

            startDate           = original.startDate
            durationSeconds     = dur
            stoppingTimeSeconds = min(stoppedDur, dur)
            stopCount           = Int((Double(original.stopCount) * frac).rounded())
            totalDistanceM      = dist
            maxSpeedMps         = speeds.max() ?? 0
            avgSpeedMps         = dur > 0 ? dist / dur : 0
            avgMovingSpeedMps   = dist / max(1, dur - stoppedDur)

            routeLatitudes      = Array(original.routeLatitudes.prefix(N))
            routeLongitudes     = Array(original.routeLongitudes.prefix(N))
            routeSpeeds         = speeds
            routeAltitudes      = Array(original.routeAltitudes.prefix(N))
            startPlaceName      = original.startPlaceName
            endPlaceName        = nil

            let ggN      = Int(frac * Double(original.ggScatterLat.count))
            ggScatterLat = Array(original.ggScatterLat.prefix(ggN))
            ggScatterFwd = Array(original.ggScatterFwd.prefix(ggN))

            rawFwd  = Array(original.rawFwd.prefix(rawN))
            rawLat  = Array(original.rawLat.prefix(rawN))
            rawVert = Array(original.rawVert.prefix(rawN))

            var types: [Int] = []; var eLats: [Double] = []
            var eLons: [Double] = []; var fmts: [String] = []
            let evN = min(original.peakEventTypes.count,
                          min(original.peakEventLats.count,
                              min(original.peakEventLons.count, original.peakEventFormatted.count)))
            for i in 0..<evN
            where DriveSession.nearestRouteIdx(lat: original.peakEventLats[i],
                                               lon: original.peakEventLons[i],
                                               lats: original.routeLatitudes,
                                               lons: original.routeLongitudes) < N {
                types.append(original.peakEventTypes[i])
                eLats.append(original.peakEventLats[i])
                eLons.append(original.peakEventLons[i])
                fmts.append(original.peakEventFormatted[i])
            }
            peakEventTypes = types; peakEventLats = eLats
            peakEventLons  = eLons; peakEventFormatted = fmts

        } else {
            let speeds      = Array(original.routeSpeeds.dropFirst(N))
            let dur         = original.durationSeconds * (1 - frac)
            let dist        = speeds.reduce(0.0, +) * dt
            let stoppedDur  = Double(speeds.filter { $0 < 0.5 }.count) * dt

            startDate           = original.startDate.addingTimeInterval(original.durationSeconds * frac)
            durationSeconds     = dur
            stoppingTimeSeconds = min(stoppedDur, dur)
            stopCount           = max(0, original.stopCount - Int((Double(original.stopCount) * frac).rounded()))
            totalDistanceM      = dist
            maxSpeedMps         = speeds.max() ?? 0
            avgSpeedMps         = dur > 0 ? dist / dur : 0
            avgMovingSpeedMps   = dist / max(1, dur - stoppedDur)

            routeLatitudes      = Array(original.routeLatitudes.dropFirst(N))
            routeLongitudes     = Array(original.routeLongitudes.dropFirst(N))
            routeSpeeds         = speeds
            routeAltitudes      = Array(original.routeAltitudes.dropFirst(N))
            startPlaceName      = nil
            endPlaceName        = original.endPlaceName

            let ggN      = Int(frac * Double(original.ggScatterLat.count))
            ggScatterLat = Array(original.ggScatterLat.dropFirst(ggN))
            ggScatterFwd = Array(original.ggScatterFwd.dropFirst(ggN))

            rawFwd  = Array(original.rawFwd.dropFirst(rawN))
            rawLat  = Array(original.rawLat.dropFirst(rawN))
            rawVert = Array(original.rawVert.dropFirst(rawN))

            var types: [Int] = []; var eLats: [Double] = []
            var eLons: [Double] = []; var fmts: [String] = []
            let evN = min(original.peakEventTypes.count,
                          min(original.peakEventLats.count,
                              min(original.peakEventLons.count, original.peakEventFormatted.count)))
            for i in 0..<evN
            where DriveSession.nearestRouteIdx(lat: original.peakEventLats[i],
                                               lon: original.peakEventLons[i],
                                               lats: original.routeLatitudes,
                                               lons: original.routeLongitudes) >= N {
                types.append(original.peakEventTypes[i])
                eLats.append(original.peakEventLats[i])
                eLons.append(original.peakEventLons[i])
                fmts.append(original.peakEventFormatted[i])
            }
            peakEventTypes = types; peakEventLats = eLats
            peakEventLons  = eLons; peakEventFormatted = fmts
        }

        // Acceleration / jerk stats zeroed — recompute() derives them from raw samples
        peakForward = 0; peakBraking = 0; avgLongitudinalAbs = 0; rmsForward = 0
        hardAccelCount = 0; hardBrakingCount = 0
        peakJerkForward = 0; peakJerkBraking = 0; avgJerkLongitudinalAbs = 0
        peakRight = 0; peakLeft = 0; avgLateralAbs = 0; rmsLateral = 0
        hardCorneringCount = 0
        peakJerkRight = 0; peakJerkLeft = 0; avgJerkLateralAbs = 0
        peakUp = 0; peakDown = 0; avgVerticalAbs = 0; rmsVertical = 0
        peakJerkUp = 0; peakJerkDown = 0; avgJerkVerticalAbs = 0
        peakNetAccel = 0; avgNetAccel = 0; rmsNet = 0; peakNetJerk = 0; avgNetJerk = 0
        surfaceEventCount = 0; smoothnessScore = 0
        lapSplitSeconds = []
    }

    private static func nearestRouteIdx(lat: Double, lon: Double,
                                        lats: [Double], lons: [Double]) -> Int {
        guard lats.count == lons.count, !lats.isEmpty else { return 0 }
        var best = 0; var bestDist = Double.infinity
        for j in 0..<lats.count {
            let d = (lat - lats[j]) * (lat - lats[j]) + (lon - lons[j]) * (lon - lons[j])
            if d < bestDist { bestDist = d; best = j }
        }
        return best
    }

    // MARK: Computed helpers

    var movingTimeSeconds: Double { max(0, durationSeconds - stoppingTimeSeconds) }

    var ggPointsStored: [GGPoint] {
        guard ggScatterLat.count == ggScatterFwd.count else { return [] }
        return zip(ggScatterLat, ggScatterFwd).map { GGPoint(lat: $0, fwd: $1) }
    }

    /// "Suburb → Suburb" label for the route; falls back to nil so callers can use the date.
    var routeLabel: String? {
        guard let start = startPlaceName else { return nil }
        if let end = endPlaceName, end != start {
            return "\(start) → \(end)"
        }
        return start
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

    /// Rebuilds surface-event annotations from the stored raw vertical samples,
    /// replacing any previously stored surface entries. Requires rawVert to be populated
    /// and at least 2 route points. Uses the same rising-edge detection as recompute().
    func recomputeSurfaceEvents(threshold: Double) {
        guard !rawVert.isEmpty, routeLatitudes.count >= 2 else { return }

        // Strip existing surface entries (rawValue 5) from the parallel arrays
        var types: [Int] = []; var lats: [Double] = []; var lons: [Double] = []; var fmts: [String] = []
        let n = min(peakEventTypes.count, min(peakEventLats.count, min(peakEventLons.count, peakEventFormatted.count)))
        for i in 0..<n where peakEventTypes[i] != 5 {
            types.append(peakEventTypes[i])
            lats.append(peakEventLats[i])
            lons.append(peakEventLons[i])
            fmts.append(peakEventFormatted[i])
        }

        // Detect rising edges in raw vertical and map sample index → nearest route coordinate
        let rawCount = rawVert.count
        let routeCount = routeLatitudes.count
        var inSE = false
        for i in 0..<rawCount {
            let vz = Double(rawVert[i])
            let nowSE = abs(vz) > threshold
            if nowSE && !inSE {
                let frac = Double(i) / Double(max(1, rawCount - 1))
                let routeIdx = min(routeCount - 1, max(0, Int(frac * Double(routeCount - 1))))
                types.append(5)
                lats.append(routeLatitudes[routeIdx])
                lons.append(routeLongitudes[routeIdx])
                fmts.append(String(format: "%.2f g", abs(vz)))
            }
            inSE = nowSE
        }

        peakEventTypes     = types
        peakEventLats      = lats
        peakEventLons      = lons
        peakEventFormatted = fmts
    }

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
