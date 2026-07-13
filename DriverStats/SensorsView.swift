//
//  SensorsView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Charts
import SwiftUI

struct SensorsView: View {
    @ObservedObject var motion: MotionManager
    @ObservedObject var location: LocationManager
    @AppStorage("ds.feltDirection") private var feltDirection = false

    var body: some View {
        List {

            if !location.isCourseReliable {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "location.slash.fill")
                            .foregroundStyle(.orange)
                        Text("GPS motion required for accurate sensor data")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.orange.opacity(0.08))
                }
            }

            Section("Gravity Level") {
                VStack(spacing: 18) {
                    GravityBubble(
                        forward: fwdValue,
                        lateral: latValue,
                        gmax: 0.6, size: 200,
                        isStable: motion.isStable,
                        isFelt: feltDirection
                    )
                    VStack(spacing: 9) {
                        BarMeter(label: "Lateral", value: latValue, max: 0.6,
                                 display: barDisplay(latValue), color: .green, bidirectional: true)
                        BarMeter(label: "Longitudinal", value: fwdValue, max: 0.6,
                                 display: barDisplay(fwdValue), color: .accentColor, bidirectional: true)
                        BarMeter(label: "Vertical", value: vertValue, max: 0.6,
                                 display: barDisplay(vertValue), color: .orange, bidirectional: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                AccelStrip(title: feltDirection ? "Longitudinal · push fwd + / push back −" : "Longitudinal · fwd + / brake −",
                           samples: motion.recentSamples, value: \.forward,
                           color: .accentColor, scale: feltDirection ? -1.0 : 1.0)
                AccelStrip(title: feltDirection ? "Lateral · push left + / push right −" : "Lateral · right + / left −",
                           samples: motion.recentSamples, value: \.lateral,
                           color: .green, scale: feltDirection ? -1.0 : 1.0)
                AccelStrip(title: "Vertical · bump + / dip −",
                           samples: motion.recentSamples, value: \.vertical,
                           color: .orange)
            } header: {
                HStack {
                    Text("Acceleration Channels")
                    Spacer()
                    Text("rolling 15 s").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .textCase(nil)
            }

            Section("Raw Readout") {
                LabeledContent("Sample rate", value: "50 Hz")
                LabeledContent("Buffer", value: "\(motion.recentSamples.count) / 300")
                LabeledContent("Stability", value: motion.isStable ? "Stable" : "Unstable")
                LabeledContent("Heading status", value: headingText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Live Sensors")
    }

    // Felt-direction-adjusted axis values, shared by the bubble and the bars.
    private var latValue: Double {
        let v = motion.displayAcceleration?.lateral ?? 0
        return feltDirection ? -v : v
    }
    private var fwdValue: Double {
        let v = motion.displayAcceleration?.forward ?? 0
        return feltDirection ? -v : v
    }
    private var vertValue: Double { motion.displayAcceleration?.vertical ?? 0 }

    private func barDisplay(_ v: Double) -> String {
        motion.displayAcceleration == nil ? "—" : String(format: "%+.2f g", v)
    }

    private var headingText: String {
        switch motion.headingStatus {
        case .noFix: return "No fix"
        case .gpsFix(let c, _, _): return String(format: "GPS fix · %.0f°", c)
        case .propagated(_, let cur, _): return String(format: "Gyro · %.0f°", cur)
        }
    }
}
