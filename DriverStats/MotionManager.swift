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

    // Reverse-drive detection: fires once per session if a ~180° course flip is seen within 45 s
    private var initialSessionCourse: Double? = nil
    private var initialSessionCourseTime: Date? = nil
    private var hasAppliedReverseFlip: Bool = false
    private let reverseDetectionWindow: TimeInterval = 45

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
        ggSamples = []
        ggDownsampleTick = 0
        shouldStoreRaw = UserDefaults.standard.object(forKey: "ds.storeRawData") as? Bool ?? true
        rawSessionFwd = []
        rawSessionLat = []
        rawSessionVert = []
        initialSessionCourse = nil
        initialSessionCourseTime = nil
        hasAppliedReverseFlip = false
        prevEffective = nil
        prevTimestamp = nil
    }

    func endSession() {
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
            }
            return PeakEvent(type: type, coordinate: data.coord, formatted: formatted)
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

        // Reverse-drive detection: if course flips ~180° within the first 45 s, the driver
        // started in reverse. Flip all accumulated data and correct going forward.
        if isSessionActive && !hasAppliedReverseFlip {
            if initialSessionCourse == nil {
                initialSessionCourse = course
                initialSessionCourseTime = Date()
            } else if let initial = initialSessionCourse, let initTime = initialSessionCourseTime {
                if Date().timeIntervalSince(initTime) < reverseDetectionWindow {
                    let delta = abs(course - initial)
                    if min(delta, 360 - delta) > 150 {
                        applyReverseFlip()
                        hasAppliedReverseFlip = true
                        initialSessionCourse = course  // Update baseline to new direction
                    }
                }
            }
        }
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
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: updateQueue) { [weak self] data, error in
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
                ggDownsampleTick += 1
                if ggDownsampleTick % 5 == 0 {
                    ggSamples.append(GGPoint(lat: sv.y, fwd: sv.x))
                    // No rolling limit — full session captured for complete envelope
                }
            }
        }
    }

    // MARK: - Reverse-drive correction

    /// Flips the forward/lateral coordinate system when a reverse-start is detected.
    /// Swaps signed peaks, event counts, and all buffered samples so the rest of the
    /// drive is recorded with the correct heading.
    private func applyReverseFlip() {
        // Signed peak stats: swap forward ↔ braking and right ↔ left (both axes invert)
        (liveStats.peakForward,      liveStats.peakBraking)      = (-liveStats.peakBraking,      -liveStats.peakForward)
        (liveStats.peakJerkForward,  liveStats.peakJerkBraking)  = (-liveStats.peakJerkBraking,  -liveStats.peakJerkForward)
        (liveStats.peakRight,        liveStats.peakLeft)          = (-liveStats.peakLeft,          -liveStats.peakRight)
        (liveStats.peakJerkRight,    liveStats.peakJerkLeft)      = (-liveStats.peakJerkLeft,      -liveStats.peakJerkRight)
        (liveStats.hardAccelCount,   liveStats.hardBrakingCount)  = (liveStats.hardBrakingCount,   liveStats.hardAccelCount)

        // Swap peak-event map entries so map pins land on the right event type
        let accel = peakTracker[.peakAccel]; peakTracker[.peakAccel] = peakTracker[.peakBraking]; peakTracker[.peakBraking] = accel
        let right = peakTracker[.peakRight]; peakTracker[.peakRight] = peakTracker[.peakLeft];    peakTracker[.peakLeft]    = right

        // Flip sign of all buffered display samples
        recentSamples = recentSamples.map {
            AccelerationSample(id: $0.id, elapsedSeconds: $0.elapsedSeconds,
                               forward: -$0.forward, lateral: -$0.lateral, vertical: $0.vertical)
        }
        ggSamples = ggSamples.map { GGPoint(lat: -$0.lat, fwd: -$0.fwd, isPeak: $0.isPeak) }

        // Push corrected stats to the published property immediately
        sessionStats = liveStats
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
