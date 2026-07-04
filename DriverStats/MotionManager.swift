//
//  MotionManager.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Combine
import CoreLocation
import CoreMotion
import Foundation

@MainActor
class MotionManager: ObservableObject {

    enum HeadingStatus {
        case noFix
        case gpsFix(course: Double, speedMps: Double, accuracyM: Double)
        case propagated(baseCourse: Double, currentCourse: Double, ageSeconds: Double)
    }

    private struct GPSFix {
        let worldForward: SIMD3<Double>
        let rotMatrix: CMRotationMatrix
        let course: Double
        let speedMps: Double
        let accuracyM: Double
        let timestamp: Date
    }

    private let motion = CMMotionManager()
    private let updateQueue = OperationQueue()

    @Published private(set) var isAvailable: Bool = false
    @Published private(set) var currentAcceleration: AccelerationComponents?
    /// Slow-refresh copy of currentAcceleration for display (~2 Hz)
    @Published private(set) var displayAcceleration: AccelerationComponents?
    @Published private(set) var headingStatus: HeadingStatus = .noFix
    @Published private(set) var currentGravity: CMAcceleration?
    @Published private(set) var isStable: Bool = false
    @Published private(set) var recentSamples: [AccelerationSample] = []
    @Published private(set) var sessionStats: SessionStats?
    @Published private(set) var isSessionActive: Bool = false

    /// When true, vertical component is zeroed in stats so road surface events
    /// don't contaminate longitudinal/lateral/net stats. Surface events are still counted.
    @Published var suppressVerticalEvents: Bool = true

    /// When true, uses a rolling average to filter sensor spikes and road noise.
    @Published var autoSmooth: Bool = true
    /// Duration of the rolling average window when autoSmooth is on (seconds).
    @Published var autoSmoothWindowSeconds: Double = 0.5
    /// Threshold for hard acceleration / braking / cornering events (g).
    @Published var hardThresholdG: Double = 0.3
    /// Threshold for road-surface (bump/pothole) events (g).
    @Published var surfaceThresholdG: Double = 0.4

    private var cancellables = Set<AnyCancellable>()

    /// Peak events recorded during the session, available after endSession()
    private(set) var peakEvents: [PeakEvent] = []

    /// All g-g scatter points for the current session (~2 Hz, no rolling limit — full drive captured)
    private(set) var ggSamples: [GGPoint] = []
    private var ggDownsampleTick = 0

    /// Raw pre-smoothing 10 Hz samples for post-hoc recomputation
    private(set) var rawSessionFwd: [Float] = []
    private(set) var rawSessionLat: [Float] = []
    private(set) var rawSessionVert: [Float] = []
    private var shouldStoreRaw = true

    // Heading orientation: sparse GPS anchors recorded during the session are used post-hoc
    // at endSession() to detect and correct any portion driven with a reversed heading.
    private struct HeadingAnchor {
        let rawSampleIndex: Int
        let ggSampleIndex: Int
        let course: Double
        let speedMps: Double
        let accuracyM: Double
    }
    private var headingAnchors: [HeadingAnchor] = []

    private var pendingGPS: (course: Double, speedMps: Double, accuracyM: Double)?
    private var lastFix: GPSFix?
    private var currentCoordinate: CLLocationCoordinate2D?

    // Stability tracking
    private var recentMagnitudes: [Double] = []
    private let stabilityWindow = 25
    private let stabilityThreshold = 0.04

    // Smoothing: 5-sample moving average reduces sensor noise before jerk/stats
    private var accelSmoothing: [SIMD3<Double>] = []
    private let smoothingN = 5

    // Peak coordinate tracking keyed by event type
    private var peakTracker: [PeakEventType: (coord: CLLocationCoordinate2D, value: Double)] = [:]

    // All surface event coordinates + peak g-value at time of detection (recorded at 10 Hz)
    private var surfaceEventCoords: [(CLLocationCoordinate2D, Double)] = []
    private var inSurfaceEventLive = false

    // Graph + stats buffer timing
    private var motionTick = 0
    private let graphDownsample = 5
    private var displayTick = 0
    private let displayDownsample = 5
    private let graphBufferSize = 300
    private var graphSampleID = 0
    private var recordingStart: Date?

    private var liveStats = SessionStats()
    private var prevEffective: SIMD3<Double>?
    private var prevTimestamp: Date?

    init() {
        isAvailable = motion.isDeviceMotionAvailable
        startMotionUpdates()
        loadPersistedSettings()
        persistSettingsOnChange()
    }

    private func loadPersistedSettings() {
        let ud = UserDefaults.standard
        if let v = ud.object(forKey: "ds.autoSmooth")            as? Bool   { autoSmooth = v }
        if let v = ud.object(forKey: "ds.autoSmoothWindow")      as? Double { autoSmoothWindowSeconds = v }
        if let v = ud.object(forKey: "ds.hardThreshold")         as? Double { hardThresholdG = v }
        if let v = ud.object(forKey: "ds.surfaceThreshold")      as? Double { surfaceThresholdG = v }
        if let v = ud.object(forKey: "ds.suppressVertical")      as? Bool   { suppressVerticalEvents = v }
    }

    private func persistSettingsOnChange() {
        let ud = UserDefaults.standard
        $autoSmooth           .dropFirst().sink { ud.set($0, forKey: "ds.autoSmooth") }           .store(in: &cancellables)
        $autoSmoothWindowSeconds.dropFirst().sink { ud.set($0, forKey: "ds.autoSmoothWindow") }   .store(in: &cancellables)
        $hardThresholdG       .dropFirst().sink { ud.set($0, forKey: "ds.hardThreshold") }        .store(in: &cancellables)
        $surfaceThresholdG    .dropFirst().sink { ud.set($0, forKey: "ds.surfaceThreshold") }     .store(in: &cancellables)
        $suppressVerticalEvents.dropFirst().sink { ud.set($0, forKey: "ds.suppressVertical") }    .store(in: &cancellables)
    }

    // MARK: - Session management

    func startSession() {
        liveStats = SessionStats()
        liveStats.hardThresholdG = hardThresholdG
        liveStats.surfaceEventThresholdG = surfaceThresholdG
        sessionStats = SessionStats()
        isSessionActive = true
        accelSmoothing = []
        peakTracker = [:]
        peakEvents = []
        surfaceEventCoords = []
        inSurfaceEventLive = false
        ggSamples = []
        ggDownsampleTick = 0
        shouldStoreRaw = UserDefaults.standard.object(forKey: "ds.storeRawData") as? Bool ?? true
        rawSessionFwd = []
        rawSessionLat = []
        rawSessionVert = []
        headingAnchors = []
        prevEffective = nil
        prevTimestamp = nil
    }

    func endSession() {
        if correctHeadingOrientation() {
            liveStats.mergeAccelerationResult(recomputeAccelerationStats())
        }
        liveStats.end()
        sessionStats = liveStats
        isSessionActive = false
        buildPeakEvents()
    }

    private func buildPeakEvents() {
        peakEvents = peakTracker.map { type, data in
            let formatted: String
            switch type {
            case .maxSpeed:    formatted = String(format: "%.0f km/h", data.value * 3.6)
            case .peakAccel:   formatted = String(format: "+%.2f g", data.value)
            case .peakBraking: formatted = String(format: "%.2f g", data.value)
            case .peakRight:   formatted = String(format: "+%.2f g", data.value)
            case .peakLeft:    formatted = String(format: "%.2f g", data.value)
            case .surface:     formatted = String(format: "%.2f g", data.value)
            }
            return PeakEvent(type: type, coordinate: data.coord, formatted: formatted)
        }
        // Append individual surface event coordinates (one entry per detected bump/pothole)
        peakEvents += surfaceEventCoords.map { coord, g in
            PeakEvent(type: .surface, coordinate: coord, formatted: String(format: "%.2f g", g))
        }
    }

    // MARK: - GPS input

    var hasValidHeading: Bool {
        if case .noFix = headingStatus { return false }
        return true
    }

    func updateFromGPS(course: Double, speedMps: Double, accuracyM: Double,
                       coordinate: CLLocationCoordinate2D) {
        currentCoordinate = coordinate

        if isSessionActive {
            let prePeak = liveStats.maxSpeedMps
            liveStats.recordSpeed(speedMps)
            if liveStats.maxSpeedMps > prePeak {
                peakTracker[.maxSpeed] = (coordinate, liveStats.maxSpeedMps)
            }
        }

        guard course >= 0,
              speedMps >= LocationManager.minReliableSpeedMps,
              accuracyM >= 0,
              accuracyM < LocationManager.maxReliableAccuracyM
        else { return }
        pendingGPS = (course: course, speedMps: speedMps, accuracyM: accuracyM)
    }

#if DEBUG
    func injectSpoofGPS(course: Double) {
        pendingGPS = (course: course, speedMps: 10.0, accuracyM: 5.0)
    }
#endif

    // MARK: - Motion processing

    private func startMotionUpdates() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: updateQueue) { [weak self] data, error in
            guard let data, error == nil else { return }
            Task { @MainActor [weak self] in
                self?.processMotionData(data)
            }
        }
    }

    private func processMotionData(_ data: CMDeviceMotion) {
        let R_now = data.attitude.rotationMatrix
        currentGravity = data.gravity

        let ua = data.userAcceleration
        let mag = (ua.x*ua.x + ua.y*ua.y + ua.z*ua.z).squareRoot()
        recentMagnitudes.append(mag)
        if recentMagnitudes.count > stabilityWindow { recentMagnitudes.removeFirst() }
        let stable = recentMagnitudes.count == stabilityWindow &&
                     (recentMagnitudes.max() ?? 1.0) < stabilityThreshold
        if isStable != stable { isStable = stable }

        if let pending = pendingGPS {
            let courseRad = pending.course * .pi / 180.0
            let forwardNEU = SIMD3<Double>(cos(courseRad), sin(courseRad), 0)
            lastFix = GPSFix(
                worldForward: forwardNEU,
                rotMatrix: R_now,
                course: pending.course,
                speedMps: pending.speedMps,
                accuracyM: pending.accuracyM,
                timestamp: Date()
            )
            if isSessionActive && shouldStoreRaw {
                headingAnchors.append(HeadingAnchor(
                    rawSampleIndex: rawSessionFwd.count,
                    ggSampleIndex: ggSamples.count,
                    course: pending.course,
                    speedMps: pending.speedMps,
                    accuracyM: pending.accuracyM
                ))
            }
            pendingGPS = nil
        }

        guard let fix = lastFix else {
            headingStatus = .noFix
            currentAcceleration = nil
            displayAcceleration = nil
            return
        }

        let R_delta = multiplyR(R_now, byTransposeOf: fix.rotMatrix)
        let forwardNEU = vecNormalize(rotateVec(fix.worldForward, by: R_delta))

        let accelDevice = SIMD3<Double>(ua.x, ua.y, ua.z)
        let accelWorld = rotateVec(accelDevice, by: R_now)

        let up = SIMD3<Double>(0, 0, 1)
        let right = vecNormalize(vecCross(up, forwardNEU))

        let fixAge = Date().timeIntervalSince(fix.timestamp)
        if fixAge < 1.5 {
            headingStatus = .gpsFix(course: fix.course, speedMps: fix.speedMps, accuracyM: fix.accuracyM)
        } else {
            let propagatedCourse = courseDegrees(from: forwardNEU)
            headingStatus = .propagated(baseCourse: fix.course, currentCourse: propagatedCourse, ageSeconds: fixAge)
        }

        // Rolling average: 5 samples (0.1 s) base, or user-configured window when autoSmooth is on
        let effectiveSmoothN = autoSmooth ? max(1, Int(autoSmoothWindowSeconds * 50)) : smoothingN
        let rawVec = SIMD3<Double>(
            vecDot(accelWorld, forwardNEU),
            vecDot(accelWorld, right),
            vecDot(accelWorld, up)
        )
        accelSmoothing.append(rawVec)
        if accelSmoothing.count > effectiveSmoothN { accelSmoothing.removeFirst() }
        let sv = accelSmoothing.reduce(SIMD3<Double>.zero, +) / Double(accelSmoothing.count)

        let rawVertical = rawVec.z
        let effectiveZ = suppressVerticalEvents ? 0.0 : sv.z

        let now = Date()
        let components = AccelerationComponents(forward: sv.x, lateral: sv.y, vertical: sv.z, timestamp: now)
        currentAcceleration = components

        if isSessionActive {
            let preForward = liveStats.peakForward
            let preBraking = liveStats.peakBraking
            let preRight   = liveStats.peakRight
            let preLeft    = liveStats.peakLeft

            liveStats.recordAcceleration(
                forward: sv.x, lateral: sv.y,
                rawVertical: rawVertical, effectiveVertical: effectiveZ
            )

            if let coord = currentCoordinate {
                if liveStats.peakForward > preForward { peakTracker[.peakAccel]   = (coord, liveStats.peakForward) }
                if liveStats.peakBraking < preBraking { peakTracker[.peakBraking] = (coord, liveStats.peakBraking) }
                if liveStats.peakRight   > preRight   { peakTracker[.peakRight]   = (coord, liveStats.peakRight) }
                if liveStats.peakLeft    < preLeft    { peakTracker[.peakLeft]    = (coord, liveStats.peakLeft) }
            }

            if let prev = prevEffective, let prevT = prevTimestamp {
                let dt = now.timeIntervalSince(prevT)
                if dt > 0 {
                    liveStats.recordJerk(
                        forward:  (sv.x    - prev.x) / dt,
                        lateral:  (sv.y    - prev.y) / dt,
                        vertical: (effectiveZ - prev.z) / dt
                    )
                }
            }
        }

        prevEffective = SIMD3<Double>(sv.x, sv.y, effectiveZ)
        prevTimestamp = now

        displayTick += 1
        if displayTick % displayDownsample == 0 {
            displayAcceleration = components
        }

        motionTick += 1
        if motionTick % graphDownsample == 0 {
            if recordingStart == nil { recordingStart = Date() }
            let elapsed = Date().timeIntervalSince(recordingStart!)
            recentSamples.append(AccelerationSample(
                id: graphSampleID,
                elapsedSeconds: elapsed,
                forward: sv.x, lateral: sv.y, vertical: sv.z
            ))
            graphSampleID += 1
            if recentSamples.count > graphBufferSize { recentSamples.removeFirst() }
            if isSessionActive {
                sessionStats = liveStats
                if shouldStoreRaw {
                    rawSessionFwd.append(Float(rawVec.x))
                    rawSessionLat.append(Float(rawVec.y))
                    rawSessionVert.append(Float(rawVec.z))
                }
                // Record surface event coordinate on each rising edge (matches 10 Hz recompute logic)
                let isSurfaceNow = abs(rawVec.z) > surfaceThresholdG
                if isSurfaceNow && !inSurfaceEventLive, let coord = currentCoordinate {
                    surfaceEventCoords.append((coord, abs(rawVec.z)))
                }
                inSurfaceEventLive = isSurfaceNow
                ggDownsampleTick += 1
                if ggDownsampleTick % 5 == 0 {
                    ggSamples.append(GGPoint(lat: sv.y, fwd: sv.x))
                    // No rolling limit — full session captured for complete envelope
                }
            }
        }
    }

    // MARK: - Heading orientation correction

    /// Computes a quality-weighted canonical forward heading from the drive's best GPS anchors,
    /// then negates fwd+lat for any raw sample whose recorded GPS course opposed that canonical
    /// direction. Returns true if any samples were corrected.
    @discardableResult
    private func correctHeadingOrientation() -> Bool {
        guard rawSessionFwd.count >= 10, !headingAnchors.isEmpty else { return false }

        // Quality-weighted circular mean — only use fast, accurate fixes
        let quality = headingAnchors.filter { $0.speedMps > 5.0 && $0.accuracyM < 25.0 }
        guard quality.count >= 2 else { return false }

        var sinSum = 0.0, cosSum = 0.0, totalWeight = 0.0
        for a in quality {
            let w = a.speedMps * a.speedMps / max(a.accuracyM, 1.0)
            let rad = a.course * .pi / 180.0
            sinSum += w * sin(rad)
            cosSum += w * cos(rad)
            totalWeight += w
        }

        // If headings are too scattered (e.g. many back-and-forth turns), don't correct
        let magnitude = (sinSum * sinSum + cosSum * cosSum).squareRoot() / totalWeight
        guard magnitude > 0.3 else { return false }

        let norm = (sinSum * sinSum + cosSum * cosSum).squareRoot()
        let canonicalCos = cosSum / norm
        let canonicalSin = sinSum / norm

        // Flip raw samples whose active GPS course opposed canonical forward
        var flippedAny = false
        var anchorIdx = 0
        var lastCosCourse = 0.0, lastSinCourse = 0.0, hasActiveCourse = false

        for sampleIdx in 0..<rawSessionFwd.count {
            while anchorIdx < headingAnchors.count &&
                  headingAnchors[anchorIdx].rawSampleIndex <= sampleIdx {
                let rad = headingAnchors[anchorIdx].course * .pi / 180.0
                lastCosCourse = cos(rad)
                lastSinCourse = sin(rad)
                hasActiveCourse = true
                anchorIdx += 1
            }
            guard hasActiveCourse else { continue }
            if lastCosCourse * canonicalCos + lastSinCourse * canonicalSin < 0 {
                rawSessionFwd[sampleIdx] = -rawSessionFwd[sampleIdx]
                rawSessionLat[sampleIdx] = -rawSessionLat[sampleIdx]
                flippedAny = true
            }
        }

        // Correct g-g scatter with the same anchor pass
        anchorIdx = 0; hasActiveCourse = false; lastCosCourse = 0; lastSinCourse = 0
        for ggIdx in 0..<ggSamples.count {
            while anchorIdx < headingAnchors.count &&
                  headingAnchors[anchorIdx].ggSampleIndex <= ggIdx {
                let rad = headingAnchors[anchorIdx].course * .pi / 180.0
                lastCosCourse = cos(rad)
                lastSinCourse = sin(rad)
                hasActiveCourse = true
                anchorIdx += 1
            }
            guard hasActiveCourse else { continue }
            if lastCosCourse * canonicalCos + lastSinCourse * canonicalSin < 0 {
                let p = ggSamples[ggIdx]
                ggSamples[ggIdx] = GGPoint(lat: -p.lat, fwd: -p.fwd, isPeak: p.isPeak)
            }
        }

        return flippedAny
    }

    /// Replays the (corrected) raw 10 Hz samples through a fresh SessionStats accumulator
    /// and returns it. Used to rebuild acceleration stats after heading correction.
    private func recomputeAccelerationStats() -> SessionStats {
        var acc = SessionStats()
        acc.hardThresholdG = hardThresholdG
        acc.surfaceEventThresholdG = surfaceThresholdG

        let sampleRate = 10
        let smoothN = autoSmooth ? max(1, Int(autoSmoothWindowSeconds * Double(sampleRate))) : 1
        var buf: [SIMD3<Double>] = []
        var prev: SIMD3<Double>? = nil
        let dt = 1.0 / Double(sampleRate)

        for i in 0..<rawSessionFwd.count {
            let raw = SIMD3<Double>(Double(rawSessionFwd[i]), Double(rawSessionLat[i]), Double(rawSessionVert[i]))
            buf.append(raw)
            if buf.count > smoothN { buf.removeFirst() }
            let sv = buf.reduce(.zero, +) / Double(buf.count)
            let effectiveZ = suppressVerticalEvents ? 0.0 : sv.z

            acc.recordAcceleration(
                forward: sv.x, lateral: sv.y,
                rawVertical: raw.z, effectiveVertical: effectiveZ
            )
            if let p = prev {
                acc.recordJerk(
                    forward:  (sv.x - p.x) / dt,
                    lateral:  (sv.y - p.y) / dt,
                    vertical: (effectiveZ - p.z) / dt
                )
            }
            prev = SIMD3<Double>(sv.x, sv.y, effectiveZ)
        }

        return acc
    }

    // MARK: - Math helpers

    private func courseDegrees(from v: SIMD3<Double>) -> Double {
        var deg = atan2(v.y, v.x) * 180.0 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    private func multiplyR(_ a: CMRotationMatrix, byTransposeOf b: CMRotationMatrix) -> CMRotationMatrix {
        CMRotationMatrix(
            m11: a.m11*b.m11 + a.m12*b.m12 + a.m13*b.m13,
            m12: a.m11*b.m21 + a.m12*b.m22 + a.m13*b.m23,
            m13: a.m11*b.m31 + a.m12*b.m32 + a.m13*b.m33,
            m21: a.m21*b.m11 + a.m22*b.m12 + a.m23*b.m13,
            m22: a.m21*b.m21 + a.m22*b.m22 + a.m23*b.m23,
            m23: a.m21*b.m31 + a.m22*b.m32 + a.m23*b.m33,
            m31: a.m31*b.m11 + a.m32*b.m12 + a.m33*b.m13,
            m32: a.m31*b.m21 + a.m32*b.m22 + a.m33*b.m23,
            m33: a.m31*b.m31 + a.m32*b.m32 + a.m33*b.m33
        )
    }

    private func rotateVec(_ v: SIMD3<Double>, by r: CMRotationMatrix) -> SIMD3<Double> {
        SIMD3(
            r.m11*v.x + r.m12*v.y + r.m13*v.z,
            r.m21*v.x + r.m22*v.y + r.m23*v.z,
            r.m31*v.x + r.m32*v.y + r.m33*v.z
        )
    }

    private func vecDot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x*b.x + a.y*b.y + a.z*b.z
    }

    private func vecCross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
    }

    private func vecNormalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let len = (v.x*v.x + v.y*v.y + v.z*v.z).squareRoot()
        guard len > 1e-10 else { return SIMD3(0, 1, 0) }
        return SIMD3(v.x/len, v.y/len, v.z/len)
    }
}
