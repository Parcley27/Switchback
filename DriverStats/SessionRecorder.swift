//
//  SessionRecorder.swift
//  DriverStats
//

import Combine
import CoreLocation
import Foundation
import SwiftData

// Manages the lifecycle of an in-progress drive recording in SwiftData.
// A draft DriveSession is inserted at recording start and refreshed every 5 minutes so
// that a crash never loses the whole drive. On Stop, the draft is finalized with the full
// SessionResult. Any orphaned drafts from a prior crash are recovered on next launch.
@MainActor
final class SessionRecorder: ObservableObject {
    private(set) var draft: DriveSession?
    private weak var locationRef: LocationManager?
    private weak var motionRef: MotionManager?
    private var contextRef: ModelContext?
    private var snapshotTask: Task<Void, Never>?
    let keepAlive = RecordingKeepAlive()

    private static let snapshotIntervalSeconds: Double = 300

    // MARK: - Lifecycle

    // Call immediately after location.startTrack() / motion.startSession().
    func begin(location: LocationManager, motion: MotionManager, context: ModelContext) {
        guard draft == nil else { return }
        locationRef = location
        motionRef = motion
        contextRef = context

        let session = DriveSession()
        session.startDate = Date()
        session.isDraft = true
        context.insert(session)
        try? context.save()
        draft = session

        keepAlive.start()
        startSnapshotLoop()
    }

    // Cancel the periodic timer before calling motion.endSession() so the last snapshot
    // doesn't race with the final SessionResult build.
    func cancelTimer() {
        snapshotTask?.cancel()
        snapshotTask = nil
    }

    // Apply the final SessionResult to the draft and clear isDraft. Returns the session.
    // Falls back to inserting a fresh session if no draft is available.
    func finalize(result: SessionResult, context: ModelContext) -> DriveSession {
        snapshotTask?.cancel()
        snapshotTask = nil
        keepAlive.stop()

        let session: DriveSession
        if let existing = draft {
            existing.apply(result: result)
            existing.isDraft = false
            session = existing
        } else {
            session = DriveSession(result: result)
            context.insert(session)
        }
        try? context.save()
        draft = nil
        locationRef = nil
        motionRef = nil
        contextRef = nil
        return session
    }

    // MARK: - Crash recovery

    // Call on app launch (when not actively recording) to finalize any drafts left over
    // from a prior crash. Reads motion settings from UserDefaults to recompute stats.
    func recoverDrafts(context: ModelContext) {
        let ud = UserDefaults.standard
        let hardThreshold = (ud.object(forKey: "ds.hardThreshold") as? Double) ?? 0.3
        let surfaceThreshold = (ud.object(forKey: "ds.surfaceThreshold") as? Double) ?? 0.4
        let autoSmooth = (ud.object(forKey: "ds.autoSmooth") as? Bool) ?? true
        let smoothWindow = (ud.object(forKey: "ds.autoSmoothWindow") as? Double) ?? 0.5
        let suppressVertical = (ud.object(forKey: "ds.suppressVertical") as? Bool) ?? true

        // Fetch all sessions and filter in Swift to avoid SwiftData predicate issues
        // on the isDraft column immediately after lightweight schema migration.
        let descriptor = FetchDescriptor<DriveSession>()
        guard let all = try? context.fetch(descriptor) else { return }
        let orphans = all.filter { $0.isDraft }
        guard !orphans.isEmpty else { return }
        for orphan in orphans {
            orphan.recompute(
                hardThreshold: hardThreshold,
                surfaceThreshold: surfaceThreshold,
                autoSmooth: autoSmooth,
                smoothWindowSeconds: smoothWindow,
                suppressVertical: suppressVertical
            )
            orphan.isDraft = false
        }
        try? context.save()
    }

    // MARK: - Private

    private func startSnapshotLoop() {
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.snapshotIntervalSeconds))
                guard !Task.isCancelled else { break }
                self?.snapshot()
            }
        }
    }

    private func snapshot() {
        guard let draft,
              let loc = locationRef,
              let mot = motionRef,
              let ctx = contextRef else { return }

        let track = loc.trackPoints
        draft.routeLatitudes  = track.map(\.coordinate.latitude)
        draft.routeLongitudes = track.map(\.coordinate.longitude)
        draft.routeSpeeds     = track.map(\.speedMps)
        draft.routeAltitudes  = track.map(\.altitudeM)

        if let stats = mot.sessionStats {
            draft.startDate       = stats.startDate
            draft.durationSeconds = stats.durationSeconds
            draft.totalDistanceM  = stats.totalDistanceM
            draft.maxSpeedMps     = stats.maxSpeedMps
            draft.avgSpeedMps     = stats.avgSpeedMps
        }

        draft.rawFwd        = mot.rawSessionFwd
        draft.rawLat        = mot.rawSessionLat
        draft.rawVert       = mot.rawSessionVert
        draft.ggScatterLat  = mot.ggSamples.map(\.lat)
        draft.ggScatterFwd  = mot.ggSamples.map(\.fwd)

        try? ctx.save()
    }
}
