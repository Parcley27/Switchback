//
//  ReadinessView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Combine
import SwiftData
import SwiftUI

struct ReadinessView: View {
    @ObservedObject var motion: MotionManager
    @ObservedObject var location: LocationManager
    @Binding var isTracking: Bool
    @EnvironmentObject private var recorder: SessionRecorder
    @Environment(\.modelContext) private var modelContext

    @State private var countdown: Int? = nil
    @State private var countdownTask: Task<Void, Never>? = nil

#if DEBUG
    @State private var spoofGPSEnabled = false
    @State private var spoofCourse: Double = 90
#endif

    var body: some View {
        List {

            Section("Signal Acquisition") {
                HStack(spacing: 20) {
                    VStack(spacing: 6) {
                        HStack(alignment: .bottom, spacing: 5) {
                            ForEach(0..<4) { i in
                                let thresholds: [Double] = [30, 20, 10, 5]
                                let lit = location.horizontalAccuracy > 0
                                         && location.horizontalAccuracy <= thresholds[i]
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(lit ? accuracyZone : Color(.systemFill))
                                    .frame(width: 10, height: CGFloat(14 + i * 10))
                                    .animation(.easeInOut(duration: 0.3), value: lit)
                            }
                        }
                        Text(location.horizontalAccuracy > 0
                             ? String(format: "%.1f m", location.horizontalAccuracy)
                             : "No fix")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(accuracyZone)
                    }

                    Divider().frame(height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("GPS accuracy").font(.caption).foregroundStyle(.secondary)
                        Text(accuracyDescription).font(.headline).foregroundStyle(accuracyZone)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Speed").font(.caption).foregroundStyle(.secondary)
                        Text(location.speed > 0
                             ? String(format: "%.0f km/h", location.speed * 3.6)
                             : "—")
                            .font(.system(.headline, design: .monospaced))
                            .monospacedDigit()
                    }
                }
            }

            Section("Sensors") {
                sensorRow(icon: "gauge.with.dots.needle.67percent",
                          state: motion.isAvailable ? .ok : .bad,
                          label: "Accelerometer", detail: "±8 g · 50 Hz")
                sensorRow(icon: "gyroscope",
                          state: motion.isAvailable ? .ok : .bad,
                          label: "Gyroscope", detail: "50 Hz")
                sensorRow(icon: "location.fill",
                          state: gpsAccessState,
                          label: "GPS access", detail: gpsAccessDetail)
                sensorRow(icon: "location.north.line.fill",
                          state: motion.hasValidHeading ? .ok : .warn,
                          label: "Heading lock", detail: "Needs ≥ 2 m/s")
            }

            Section("GPS") {
                LabeledContent("Horizontal accuracy", value: accuracyText)
                LabeledContent("Speed", value: speedText)
                LabeledContent("Course", value: courseText)
                LabeledContent("Altitude", value: altitudeText)
            }

#if DEBUG
            Section("Debug") {
                Toggle("Spoof GPS heading", isOn: $spoofGPSEnabled)
                if spoofGPSEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Course: \(String(format: "%.0f", spoofCourse))°")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Slider(value: $spoofCourse, in: 0...359)
                    }
                    .padding(.vertical, 4)
                    Text("Injected at 10 m/s, 5 m accuracy. DEBUG only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
#endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ready to Record")
        .safeAreaInset(edge: .bottom) {
            Group {
                if let c = countdown {
                    Button(action: cancelCountdown) {
                        HStack(spacing: 6) {
                            Text("Starting in \(c)…").font(.headline)
                            Text("· tap to cancel").font(.subheadline).opacity(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.orange)
                    .padding(.horizontal, 16)
                } else {
                    Button(action: beginCountdown) {
                        Text("Start Recording")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.accentColor)
                    .disabled(!location.hasValidFix)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
#if DEBUG
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard spoofGPSEnabled else { return }
            motion.injectSpoofGPS(course: spoofCourse)
        }
        .onChange(of: spoofGPSEnabled) { _, isOn in if isOn { motion.injectSpoofGPS(course: spoofCourse) } }
        .onChange(of: spoofCourse) { _, c in guard spoofGPSEnabled else { return }; motion.injectSpoofGPS(course: c) }
#endif
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sensorRow(icon: String, state: LampState, label: String, detail: String) -> some View {
        LabeledContent {
            Image(systemName: statusSymbol(state))
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor(state))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(Color(.label))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(.secondary)
            }
        }
    }

    private func statusSymbol(_ s: LampState) -> String {
        switch s {
        case .ok:   return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad:  return "xmark.circle.fill"
        case .off:  return "circle.dotted"
        }
    }

    private func statusColor(_ s: LampState) -> Color {
        switch s {
        case .ok:   return .green
        case .warn: return .orange
        case .bad:  return .red
        case .off:  return Color(.tertiaryLabel)
        }
    }

    private var accuracyZone: Color {
        guard location.horizontalAccuracy > 0 else { return Color(.tertiaryLabel) }
        return location.horizontalAccuracy <= 5 ? .green
             : location.horizontalAccuracy <= 15 ? .orange : .red
    }

    private var accuracyDescription: String {
        guard location.horizontalAccuracy > 0 else { return "No fix" }
        if location.horizontalAccuracy <= 5  { return "Excellent" }
        if location.horizontalAccuracy <= 15 { return "Good" }
        if location.horizontalAccuracy <= 30 { return "Fair" }
        return "Poor"
    }

    private var gpsAccessState: LampState {
        switch location.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return location.hasValidFix ? .ok : .warn
        case .notDetermined: return .off
        default: return .bad
        }
    }

    private var gpsAccessDetail: String {
        switch location.authorizationStatus {
        case .authorizedWhenInUse: return "When in use"
        case .authorizedAlways:    return "Always"
        case .notDetermined:       return "Not requested"
        default:                   return "Denied"
        }
    }

    private var accuracyText: String {
        guard location.horizontalAccuracy >= 0 else { return "No fix" }
        return String(format: "%.1f m", location.horizontalAccuracy)
    }

    private var speedText: String {
        guard location.speed >= 0 else { return "No fix" }
        return String(format: "%.1f km/h", location.speed * 3.6)
    }

    private var courseText: String {
        guard location.course >= 0 else { return "No heading" }
        return String(format: "%.0f°", location.course)
    }

    private var altitudeText: String { String(format: "%.0f m", location.altitudeM) }

    private func beginCountdown() {
        countdownTask?.cancel()
        countdownTask = Task {
            for i in stride(from: 3, through: 1, by: -1) {
                countdown = i
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { countdown = nil; return }
            }
            guard !Task.isCancelled else { countdown = nil; return }
            countdown = nil
            location.startTrack()
            motion.startSession()
            recorder.begin(location: location, motion: motion, context: modelContext)
            isTracking = true
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }
}
