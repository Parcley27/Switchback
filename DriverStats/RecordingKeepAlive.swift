//
//  RecordingKeepAlive.swift
//  DriverStats
//

import AVFoundation
import Foundation

// Keeps the process alive while recording in the background by running a silent, mixable
// audio session. This piggybacks on the 'audio' UIBackgroundMode so CoreMotion callbacks
// keep delivering when the user switches to another app (e.g. a music player).
// The .mixWithOthers option ensures the user's music is never interrupted or ducked.
@MainActor
final class RecordingKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var notificationObserver: NSObjectProtocol?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        do {
            let avSession = AVAudioSession.sharedInstance()
            try avSession.setCategory(.playback, options: .mixWithOthers)
            try avSession.setActive(true)

            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()

            // A 0.1 s buffer of silence, looped indefinitely
            let frameCount = AVAudioFrameCount(format.sampleRate * 0.1)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount  // channel data defaults to all zeros = silence
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isRunning = true

            notificationObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        } catch {
            // If audio session fails, the location background mode still keeps GPS alive.
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        if let obs = notificationObserver { NotificationCenter.default.removeObserver(obs) }
        notificationObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !player.isPlaying { player.play() }
    }
}
