//
//  TripView.swift
//  DriverStats
//

import CoreLocation
import MapKit
import SwiftData
import SwiftUI

// MARK: - Trip detail view

struct TripView: View {
    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext

    @State private var isRenamingTrip = false
    @State private var pendingName = ""
    @State private var fillingGap: ObjectIdentifier? = nil
    @State private var gapFillError: String? = nil

    private let gapThresholdMeters: Double = 500

    private var ordered: [DriveSession] { trip.orderedSessions }
    private var gaps: [(first: DriveSession, second: DriveSession, gapSeconds: Double, gapMeters: Double)] {
        trip.sessionGaps()
    }

    var body: some View {
        List {
            // Map section
            if !trip.sessions.isEmpty {
                Section {
                    AllDrivesMapView(sessions: trip.sessions)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .listRowInsets(EdgeInsets())
                }
            }

            // Stats section
            Section {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    StatCell(label: "Distance",
                             value: formatDistance(trip.totalDistanceM))
                    StatCell(label: "Drives",
                             value: "\(trip.driveCount)")
                    StatCell(label: "Drive Time",
                             value: formatDuration(trip.totalDrivingSeconds))
                    StatCell(label: "Total Span",
                             value: formatDuration(trip.totalSpanSeconds))
                    StatCell(label: "Stops",
                             value: "\(trip.totalStops)")
                    if !trip.scoredSessions.isEmpty {
                        StatCell(label: "Avg Score",
                                 value: String(format: "%.0f", trip.avgSmoothnessScore),
                                 accent: true)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            // Drives section
            Section {
                ForEach(Array(ordered.enumerated()), id: \.element.persistentModelID) { i, session in
                    NavigationLink(destination: DriveSessionView(session: session)) {
                        TripSessionRow(session: session)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            session.trip = nil
                            try? modelContext.save()
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }

                    // Gap connector row (shown when consecutive drives are far apart)
                    if i < gaps.count && gaps[i].gapMeters > gapThresholdMeters {
                        let gap = gaps[i]
                        let isLoading = fillingGap == ObjectIdentifier(gap.first)
                        GapConnectorRow(
                            gapSeconds: gap.gapSeconds,
                            gapMeters: gap.gapMeters,
                            isLoading: isLoading
                        ) {
                            Task { await fillGap(from: gap.first, to: gap.second) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    }
                }
            } header: {
                Text("Drives (\(trip.driveCount))")
                    .font(.footnote).fontWeight(.medium)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .tracking(0.3)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(trip.name.isEmpty ? "Trip" : trip.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    pendingName = trip.name
                    isRenamingTrip = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .alert("Rename Trip", isPresented: $isRenamingTrip) {
            TextField("Trip name", text: $pendingName)
            Button("Save") {
                trip.name = pendingName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Trip" : pendingName.trimmingCharacters(in: .whitespaces)
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Routing Error", isPresented: Binding(
            get: { gapFillError != nil },
            set: { if !$0 { gapFillError = nil } }
        )) {
            Button("OK", role: .cancel) { gapFillError = nil }
        } message: {
            if let err = gapFillError { Text(err) }
        }
    }

    // MARK: - Gap fill

    private func fillGap(from first: DriveSession, to second: DriveSession) async {
        guard let lastLat = first.routeLatitudes.last, let lastLon = first.routeLongitudes.last,
              let firstLat = second.routeLatitudes.first, let firstLon = second.routeLongitudes.first else { return }

        let startCoord = CLLocationCoordinate2D(latitude: lastLat, longitude: lastLon)
        let endCoord   = CLLocationCoordinate2D(latitude: firstLat, longitude: firstLon)
        let departure  = first.startDate.addingTimeInterval(first.durationSeconds)

        fillingGap = ObjectIdentifier(first)
        defer { fillingGap = nil }

        let request = MKDirections.Request()
        request.source      = MKMapItem(placemark: MKPlacemark(coordinate: startCoord))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: endCoord))
        request.transportType = .automobile

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                gapFillError = "No route found between these locations."
                return
            }
            var coords = [CLLocationCoordinate2D](
                repeating: kCLLocationCoordinate2DInvalid,
                count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: route.polyline.pointCount))

            let connector = DriveSession(
                connectingFrom: startCoord,
                to: endCoord,
                departureDate: departure,
                routeCoordinates: coords,
                estimatedDurationSeconds: route.expectedTravelTime,
                estimatedDistanceM: route.distance
            )
            modelContext.insert(connector)
            connector.trip = trip
            try? modelContext.save()
        } catch {
            gapFillError = "Couldn't get directions: \(error.localizedDescription)"
        }
    }
}

// MARK: - Drive row inside a trip

private struct TripSessionRow: View {
    let session: DriveSession
    @AppStorage("ds.geoLabels") private var geoLabels = true

    private var label: String {
        if geoLabels, let l = session.routeLabel { return l }
        return session.startDate.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Mode colour swatch
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(session.driveMode.color)
                .frame(width: 5, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if session.driveMode != .normal {
                        Label(session.driveMode.label, systemImage: session.driveMode.sfSymbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(session.driveMode.color)
                            .labelStyle(.iconOnly)
                    }
                }
                HStack(spacing: 12) {
                    Text(formatDistance(session.totalDistanceM))
                    Text(formatDuration(session.durationSeconds))
                    if session.driveMode.receivesScore {
                        Text(String(format: "%.0f pts", session.smoothnessScore))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No score")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Gap connector row

private struct GapConnectorRow: View {
    let gapSeconds: Double
    let gapMeters: Double
    let isLoading: Bool
    let onFill: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Dashed connector line
            VStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule()
                        .fill(Color.purple.opacity(0.4))
                        .frame(width: 3, height: 4)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Gap — \(formatDistance(gapMeters))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(formatDuration(gapSeconds) + " untracked")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button(action: onFill) {
                    Label("Fill Gap", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Trip card (used in history list)

struct TripCardView: View {
    let trip: Trip

    var body: some View {
        HStack(spacing: 12) {
            TripThumbnailView(trip: trip)
            .frame(width: 76, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(trip.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(trip.driveCount) drive\(trip.driveCount == 1 ? "" : "s")")
                    Text(formatDistance(trip.totalDistanceM))
                    Text(formatDuration(trip.totalDrivingSeconds))
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let start = trip.startDate {
                    Text(start.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
