//
//  HistoryView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Charts
import SwiftData
import SwiftUI

// MARK: - History List

struct HistoryView: View {
    @Query(sort: \DriveSession.startDate, order: .reverse) private var sessions: [DriveSession]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if sessions.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "car.fill",
                        description: Text("Start a tracking session to record your drive.")
                    )
                    .padding(.top, 60)
                }
            } else {
                List {
                    // Aggregate stats + smoothness trend
                    Section {
                        VStack(spacing: 18) {
                            NavigationLink(destination: HistoryStatsView(sessions: sessions)) {
                                HStack {
                                    Text("Full statistics")
                                        .font(.footnote).fontWeight(.medium)
                                        .textCase(.uppercase)
                                        .foregroundStyle(.secondary)
                                        .tracking(0.3)
                                }
                            }
                            .buttonStyle(.plain)
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                                spacing: 10
                            ) {
                                StatCell(label: "Avg score",
                                         value: String(format: "%.0f", avgScore),
                                         accent: true)
                                StatCell(label: "Best peak",
                                         value: String(format: "%.2f", bestPeakG),
                                         unit: "g")
                                StatCell(label: "All drives",
                                         value: "\(sessions.count)")
                                StatCell(label: "This week",
                                         value: String(format: "%.0f", thisWeekKm),
                                         unit: "km")
                                StatCell(label: "Total dist",
                                         value: String(format: "%.0f", totalKm),
                                         unit: "km")
                                StatCell(label: "Total time",
                                         value: formatTotalDrivingTime(totalDuration))
                            }

                            if trendScores.count >= 3 {
                                CardSection("Smoothness trend",
                                            note: "last \(trendScores.count)",
                                            innerPadding: 12) {
                                    Chart {
                                        ForEach(Array(trendScores.enumerated()), id: \.offset) { i, score in
                                            AreaMark(x: .value("Drive", i + 1), y: .value("Score", score))
                                                .foregroundStyle(Color.accentColor.opacity(0.12))
                                            LineMark(x: .value("Drive", i + 1), y: .value("Score", score))
                                                .foregroundStyle(Color.accentColor)
                                                .lineStyle(StrokeStyle(lineWidth: 1.6))
                                        }
                                    }
                                    .chartYScale(domain: 0...100)
                                    .chartYAxis {
                                        AxisMarks(values: [0, 50, 100]) {
                                            AxisGridLine()
                                            AxisValueLabel()
                                        }
                                    }
                                    .chartXAxis {
                                        AxisMarks(values: .automatic(desiredCount: min(trendScores.count, 6))) {
                                            AxisGridLine()
                                            AxisValueLabel()
                                        }
                                    }
                                    .frame(height: 90)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    }

                    // Drive cards
                    Section {
                        ForEach(sessions) { session in
                            NavigationLink(destination: DriveSessionView(session: session)) {
                                SessionCardView(session: session)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { modelContext.delete(sessions[$0]) }
                        }
                    } header: {
                        Text("Recent Drives")
                            .font(.footnote).fontWeight(.medium)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .tracking(0.3)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton().disabled(sessions.isEmpty)
            }
        }
    }

    // MARK: - Aggregates

    private var totalKm: Double {
        sessions.reduce(0) { $0 + $1.totalDistanceM } / 1000
    }

    private var thisWeekKm: Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions.filter { $0.startDate > cutoff }.reduce(0) { $0 + $1.totalDistanceM } / 1000
    }

    private var avgScore: Double {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0) { $0 + computeScore(for: $1) } / Double(sessions.count)
    }

    private func computeScore(for s: DriveSession) -> Double {
        let movingMin = max(1.0, s.movingTimeSeconds / 60)
        let hard = Double(s.hardAccelCount + s.hardBrakingCount + s.hardCorneringCount)
        return max(0, min(100, 100 - 20 * (hard / movingMin)
            - 30 * min(max(s.rmsNet, 0), 1)
            - 8  * min(max(s.peakNetJerk / 10, 0), 1)))
    }

    private func formatTotalDrivingTime(_ seconds: Double) -> String {
        let totalMin = Int(seconds) / 60
        let days  = totalMin / (24 * 60)
        let hours = (totalMin % (24 * 60)) / 60
        let mins  = totalMin % 60
        if days > 0  { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private var bestPeakG: Double {
        sessions.map { $0.peakNetAccel }.max() ?? 0
    }

    private var totalDuration: Double {
        sessions.reduce(0) { $0 + $1.durationSeconds }
    }

    private var trendScores: [Int] {
        Array(sessions.prefix(12).reversed().map { Int($0.smoothnessScore) })
    }
}

// MARK: - Drive card row

private struct SessionCardView: View {
    let session: DriveSession
    @AppStorage("ds.showDrivingScore") private var showDrivingScore = true

    private var thumbnailTrack: [RoutePoint] {
        let pts = session.routePoints
        guard pts.count > 40 else { return pts }
        let step = max(1, pts.count / 40)
        return stride(from: 0, to: pts.count, by: step).map { pts[$0] }
    }

    private var score: Int {
        let movingMin = max(1.0, session.movingTimeSeconds / 60)
        let hard = Double(session.hardAccelCount + session.hardBrakingCount + session.hardCorneringCount)
        let v = 100 - 20 * (hard / movingMin)
            - 30 * min(max(session.rmsNet, 0), 1)
            - 8  * min(max(session.peakNetJerk / 10, 0), 1)
        return Int(max(0, min(100, v)))
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mini route map thumbnail
            Group {
                if session.routePoints.count >= 2 {
                    RouteMapView(track: thumbnailTrack, peakEvents: [], thumbnailMode: true)
                        .allowsHitTesting(false)
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 76, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center) {
                    Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 14.5, weight: .semibold))
                    Spacer()
                    if showDrivingScore {
                        ScoreRing(value: score, size: 34)
                    }
                }

                HStack(spacing: 12) {
                    Text(formatDistance(session.totalDistanceM))
                    Text(formatDuration(session.durationSeconds))
                    Text("\(Int(session.maxSpeedMps * 3.6)) km/h")
                        .foregroundStyle(Color.accentColor)
                    Text(String(format: "%.2f g", session.peakNetAccel))
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                let hardTotal = session.hardAccelCount + session.hardBrakingCount + session.hardCorneringCount
                Text("\(hardTotal) hard event\(hardTotal == 1 ? "" : "s") logged")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
