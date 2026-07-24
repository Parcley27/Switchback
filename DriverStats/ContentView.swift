//
//  ContentView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import CoreLocation
import SwiftData
import SwiftUI

struct ContentView: View {
    @StateObject private var motion = MotionManager()
    @StateObject private var location = LocationManager()
    @StateObject private var recorder = SessionRecorder()
    @State private var isTracking = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            Tab("Record", systemImage: "gauge.with.dots.needle.67percent") {
                NavigationStack {
                    if isTracking {
                        TrackingView(motion: motion, location: location, isTracking: $isTracking)
                    } else {
                        ReadinessView(motion: motion, location: location, isTracking: $isTracking)
                    }
                }
            }

            Tab("Live", systemImage: "waveform.path") {
                NavigationStack {
                    SensorsView(motion: motion, location: location)
                }
            }

            Tab("History", systemImage: "clock.arrow.circlepath") {
                NavigationStack {
                    HistoryView()
                }
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack {
                    SettingsView(motion: motion)
                }
            }
        }
        .tint(.accentColor)
        .environmentObject(recorder)
        .onAppear {
            location.requestPermissionAndStart()
            recorder.recoverDrafts(context: modelContext)
        }
        .onChange(of: location.lastUpdate) { _, _ in
            motion.updateFromGPS(
                course: location.course,
                speedMps: location.speed,
                accuracyM: location.horizontalAccuracy,
                coordinate: location.coordinate
            )
        }
    }
}

#Preview {
    ContentView()
}
