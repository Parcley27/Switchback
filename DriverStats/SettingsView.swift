//
//  SettingsView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import SwiftData
import SwiftUI

struct SettingsView: View {
    @ObservedObject var motion: MotionManager
    @Environment(\.modelContext) private var modelContext
    @AppStorage("ds.autoPause") private var autoPause: Bool = true
    @AppStorage("ds.backgroundRecording") private var backgroundRecording: Bool = false
    @AppStorage("ds.showDrivingScore") private var showDrivingScore: Bool = true
    @AppStorage("ds.feltDirection") private var feltDirection: Bool = false
    @AppStorage("ds.storeRawData") private var storeRawData: Bool = true
    @AppStorage("ds.keepScreenOn") private var keepScreenOn: Bool = false
    @AppStorage("ds.mergeWindowMinutes") private var mergeWindowMinutes: Double = 15
    @AppStorage("ds.geoLabels") private var geoLabels: Bool = true
    @AppStorage("ds.showSurfaceEvents") private var showSurfaceEvents: Bool = false
    
    @Environment(\.openURL) var openURL

    @State private var needsRecompute = false
    @State private var showEraseConfirmation = false

    var body: some View {
        List {

            // MARK: Recording
            Section("Recording") {
                Toggle(isOn: $motion.suppressVerticalEvents) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suppress road-surface spikes")
                        Text("Bumps excluded from g-stats; still counted as surface events.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                Toggle(isOn: $motion.autoSmooth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-smooth acceleration")
                        Text("Rolling average filters sensor spikes while preserving real events.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                if motion.autoSmooth {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Smooth window")
                            Spacer()
                            Text(String(format: "%.2f s", motion.autoSmoothWindowSeconds))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $motion.autoSmoothWindowSeconds, in: 0.10...1.0, step: 0.05)
                            .tint(.accentColor)
                        HStack {
                            Text("0.10 s · sensitive").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("1.0 s · smooth").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Toggle("Auto-pause when stopped", isOn: $autoPause).tint(.green)

                Toggle(isOn: $backgroundRecording) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background recording")
                        Text("Keep logging with the screen off (needs Always location access).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                Toggle(isOn: $keepScreenOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep screen on")
                        Text("Prevents the display from sleeping during a recording session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                Toggle(isOn: $storeRawData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Store raw sensor data")
                        Text("Saves 10 Hz pre-smoothing samples (~200 KB per 20-min drive) so stats can be recomputed when thresholds or smoothing change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }

            // MARK: Detection Thresholds
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hard event")
                            Text("Acceleration, braking, or cornering above this value is counted as a hard event.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(String(format: "%.2f g", motion.hardThresholdG))
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                    Slider(value: $motion.hardThresholdG, in: 0.15...0.60, step: 0.05)
                        .tint(Color.accentColor)
                    HStack {
                        Text("0.15 g — lenient").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("0.60 g — strict").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Road surface")
                            Text("Vertical spikes above this value are counted as bumps or potholes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(String(format: "%.2f g", motion.surfaceThresholdG))
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                    Slider(value: $motion.surfaceThresholdG, in: 0.20...0.80, step: 0.05)
                        .tint(Color.accentColor)
                    HStack {
                        Text("0.20 g — lenient").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("0.80 g — strict").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Detection Thresholds")
            } footer: {
                if needsRecompute {
                    Label("Recomputing session history…", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            // MARK: Sensors Display
            Section("Sensors Display") {
                Toggle(isOn: $feltDirection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Felt direction")
                        Text("Gravity level shows the force you feel rather than the car's motion. Braking feels like a forward push, so the dot moves forward.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }

            // MARK: Smoothness Score
            Section("Smoothness Score") {
                Toggle(isOn: $showDrivingScore) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show smoothness score")
                        Text("A 0–100 score for each drive. Deducts for hard events per minute of moving time (up to −20/min), sustained g-force (up to −30), and peak jerk (up to −8).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)
            }

            // MARK: History
            Section("History") {
                NavigationLink(destination: NamedLocationsView()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Named Locations")
                        Text("Tag recurring places like Home or Work — drives that start or end nearby use the name automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $geoLabels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show location names")
                        Text("Labels drives with neighborhood names (e.g. Brookswood → Creekside). Turn off to show date and time instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                Toggle(isOn: $showSurfaceEvents) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Surface events on route map")
                        Text("Show pothole and bump locations as colored circles on the single-drive map, grouped to 25 m.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.green)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Merge window")
                            Text("Two drives must end and begin within this time to be merge-eligible.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(String(format: "%.0f min", mergeWindowMinutes))
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                    Slider(value: $mergeWindowMinutes, in: 5...60, step: 5)
                        .tint(Color.accentColor)
                    HStack {
                        Text("5 min").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("60 min").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            Section("App Information") {
                
                Button() {
                    openURL(URL(string: "https://pierceoxley.ca/")!)
                    
                } label: {
                    HStack {
                        Text("Developer Website")
                        Spacer()
                        ZStack {
                            Image(systemName: "person.circle")
                            
                            Text("📅")
                                .opacity(0)
                            
                        }
                        
                    }
                }
                Button() {
                    openURL(URL(string: "https://github.com/Parcley27/Timely")!)
                    
                } label: {
                    HStack {
                        Text("Switchback Github")
                        Spacer()
                        ZStack {
                            Image(systemName: "arrow.up.forward.app")
                            
                            Text("📅")
                                .opacity(0)
                            
                        }
                        
                    }
                }
                
                Text("Version")
                    .badge("Beta v0.1 - Build 1 (29)")
                
            }
            
            // MARK: Danger Zone
            Section("Danger Zone") {
                Button {
                    motion.hardThresholdG          = 0.30
                    motion.surfaceThresholdG       = 0.40
                    motion.autoSmoothWindowSeconds = 0.50
                    motion.autoSmooth              = true
                    motion.suppressVerticalEvents  = true
                    autoPause              = true
                    backgroundRecording    = false
                    keepScreenOn           = false
                    mergeWindowMinutes     = 15
                } label: {
                    HStack {
                        Text("Restore Defaults")
                        Spacer()
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                .foregroundStyle(Color(.label))

                Button(role: .destructive) {
                    showEraseConfirmation = true
                } label: {
                    HStack {
                        Text("Erase All Drives")
                        Spacer()
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .onChange(of: motion.hardThresholdG)          { needsRecompute = true }
        .onChange(of: motion.surfaceThresholdG)       { needsRecompute = true }
        .onChange(of: motion.autoSmoothWindowSeconds) { needsRecompute = true }
        .onChange(of: motion.autoSmooth)              { needsRecompute = true }
        .onChange(of: motion.suppressVerticalEvents)  { needsRecompute = true }
        .task(id: needsRecompute) {
            guard needsRecompute else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            recomputeAllSessions()
            needsRecompute = false
        }
        .alert("Erase All Drives?", isPresented: $showEraseConfirmation) {
            Button("Erase All", role: .destructive, action: eraseAllDrives)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all recorded sessions. This cannot be undone.")
        }
    }

    private func recomputeAllSessions() {
        let descriptor = FetchDescriptor<DriveSession>()
        guard let sessions = try? modelContext.fetch(descriptor) else { return }
        for session in sessions {
            session.recompute(
                hardThreshold: motion.hardThresholdG,
                surfaceThreshold: motion.surfaceThresholdG,
                autoSmooth: motion.autoSmooth,
                smoothWindowSeconds: motion.autoSmoothWindowSeconds,
                suppressVertical: motion.suppressVerticalEvents
            )
            session.recomputeSurfaceEvents(threshold: motion.surfaceThresholdG)
        }
        try? modelContext.save()
    }

    private func eraseAllDrives() {
        let descriptor = FetchDescriptor<DriveSession>()
        guard let sessions = try? modelContext.fetch(descriptor) else { return }
        sessions.forEach { modelContext.delete($0) }
        try? modelContext.save()
    }
}
