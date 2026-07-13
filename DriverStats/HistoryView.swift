//
//  HistoryView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Charts
import SwiftData
import SwiftUI

// MARK: - Filter types

private enum TimeFilter: String, CaseIterable, Hashable {
    case thisWeek  = "This Week"
    case thisMonth = "This Month"
}

private enum DurationFilter: String, CaseIterable, Hashable {
    case short  = "< 15 min"
    case medium = "15–60 min"
    case long   = "> 1 hr"

    func matches(_ seconds: Double) -> Bool {
        switch self {
        case .short:  return seconds < 900
        case .medium: return seconds >= 900 && seconds <= 3600
        case .long:   return seconds > 3600
        }
    }
}

// MARK: - History List (outer shell — owns @Query, applies .searchable)

struct HistoryView: View {
    @Query(sort: \DriveSession.startDate, order: .reverse) private var sessions: [DriveSession]
    @Query(sort: \Trip.createdDate, order: .reverse) private var trips: [Trip]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAllDrivesMap = false
    @State private var showingSurfaceMap = false
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var showMergeConfirmation = false
    @State private var pendingNewTrip: Trip? = nil

    // Search & filter
    @State private var searchText: String = ""
    @State private var activeTimeFilter: TimeFilter? = nil
    @State private var activeDurationFilter: DurationFilter? = nil
    @State private var useCustomRange: Bool = false
    @State private var showDateRangePicker: Bool = false
    @State private var customStartDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate: Date = Date()

    @AppStorage("ds.mergeWindowMinutes") private var mergeWindowMinutes: Double = 15
    @AppStorage("ds.surfaceEventsMigrated") private var surfaceEventsMigrated = false

    var body: some View {
        HistoryListContent(
            sessions: sessions,
            trips: trips,
            searchText: $searchText,
            activeTimeFilter: $activeTimeFilter,
            activeDurationFilter: $activeDurationFilter,
            useCustomRange: $useCustomRange,
            showDateRangePicker: $showDateRangePicker,
            customStartDate: $customStartDate,
            customEndDate: $customEndDate,
            editMode: $editMode,
            selection: $selection
        )
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search drives…")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button {
                    showingAllDrivesMap = true
                } label: {
                    Image(systemName: "map")
                }
                .disabled(sessions.isEmpty)
                Button {
                    showingSurfaceMap = true
                } label: {
                    Image(systemName: "car.rear.and.collision.road.lane")
                }
                .disabled(sessions.isEmpty)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if editMode == .active {
                    if mergeCandidate != nil {
                        Button("Merge") {
                            showMergeConfirmation = true
                        }
                    }
                    if selection.count >= 2 {
                        Button("Trip") {
                            performCreateTrip()
                        }
                    }
                }
                Button(editMode == .active ? "Done" : "Edit") {
                    withAnimation {
                        if editMode == .active {
                            editMode = .inactive
                            selection.removeAll()
                        } else {
                            editMode = .active
                        }
                    }
                }
                .disabled(sessions.isEmpty)
            }
        }
        .alert("Merge 2 Drives?", isPresented: $showMergeConfirmation) {
            Button("Merge", role: .destructive, action: performMerge)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The gap between these drives will count as stopping time. Both original sessions will be replaced by a single combined session.")
        }
        .sheet(item: $pendingNewTrip) { trip in
            NavigationStack {
                TripView(trip: trip)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { pendingNewTrip = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showDateRangePicker) {
            DateRangePickerSheet(
                startDate: $customStartDate,
                endDate: $customEndDate,
                isPresented: $showDateRangePicker
            ) {
                useCustomRange = true
                activeTimeFilter = nil
            }
        }
        .fullScreenCover(isPresented: $showingAllDrivesMap) {
            NavigationStack {
                AllDrivesMapView(sessions: sessions)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("All Drives")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showingAllDrivesMap = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showingSurfaceMap) {
            NavigationStack {
                SurfaceMapView(sessions: sessions)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Road Surface Map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showingSurfaceMap = false }
                        }
                    }
            }
        }
        .task {
            guard !surfaceEventsMigrated else { return }
            let threshold = (UserDefaults.standard.object(forKey: "ds.surfaceThreshold") as? Double) ?? 0.4
            for session in sessions where !session.rawVert.isEmpty {
                session.recomputeSurfaceEvents(threshold: threshold)
            }
            try? modelContext.save()
            surfaceEventsMigrated = true
        }
    }

    // MARK: - Merge logic

    private var mergeCandidate: (DriveSession, DriveSession)? {
        guard selection.count == 2 else { return nil }
        let picked = sessions.filter { selection.contains($0.persistentModelID) }
        guard picked.count == 2 else { return nil }
        let first  = picked[0].startDate <= picked[1].startDate ? picked[0] : picked[1]
        let second = picked[0].startDate <= picked[1].startDate ? picked[1] : picked[0]
        let gap = second.startDate.timeIntervalSince(
            first.startDate.addingTimeInterval(first.durationSeconds))
        guard gap >= 0, gap < mergeWindowMinutes * 60 else { return nil }
        return (first, second)
    }

    private func performMerge() {
        guard let (first, second) = mergeCandidate else { return }
        // If both sessions belong to the same trip, keep the merged result in that trip
        let sharedTrip: Trip?
        if let t1 = first.trip, let t2 = second.trip, t1.persistentModelID == t2.persistentModelID {
            sharedTrip = t1
        } else {
            sharedTrip = nil
        }
        let merged = DriveSession(merging: first, with: second)
        let ud = UserDefaults.standard
        merged.recompute(
            hardThreshold:       (ud.object(forKey: "ds.hardThreshold")    as? Double) ?? 0.3,
            surfaceThreshold:    (ud.object(forKey: "ds.surfaceThreshold") as? Double) ?? 0.4,
            autoSmooth:          (ud.object(forKey: "ds.autoSmooth")       as? Bool)   ?? true,
            smoothWindowSeconds: (ud.object(forKey: "ds.autoSmoothWindow") as? Double) ?? 0.5,
            suppressVertical:    (ud.object(forKey: "ds.suppressVertical") as? Bool)   ?? true
        )
        modelContext.insert(merged)
        merged.trip = sharedTrip
        modelContext.delete(first)
        modelContext.delete(second)
        try? modelContext.save()
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }

    // MARK: - Trip creation

    private func performCreateTrip() {
        guard selection.count >= 2 else { return }
        let picked = sessions.filter { selection.contains($0.persistentModelID) }
        guard picked.count >= 2 else { return }
        let trip = Trip()
        modelContext.insert(trip)
        for session in picked {
            session.trip = trip
        }
        try? modelContext.save()
        selection.removeAll()
        withAnimation { editMode = .inactive }
        pendingNewTrip = trip
    }
}

// MARK: - History list content (child — can read isSearching)

private struct HistoryListContent: View {
    let sessions: [DriveSession]
    let trips: [Trip]
    @Binding var searchText: String
    @Binding var activeTimeFilter: TimeFilter?
    @Binding var activeDurationFilter: DurationFilter?
    @Binding var useCustomRange: Bool
    @Binding var showDateRangePicker: Bool
    @Binding var customStartDate: Date
    @Binding var customEndDate: Date
    @Binding var editMode: EditMode
    @Binding var selection: Set<PersistentIdentifier>

    @Environment(\.modelContext) private var modelContext
    @Environment(\.isSearching) private var isSearching

    private var isFiltering: Bool {
        isSearching || !searchText.isEmpty || activeTimeFilter != nil || activeDurationFilter != nil || useCustomRange
    }

    private var filteredSessions: [DriveSession] {
        var result = sessions

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { session in
                let label = session.routeLabel?.lowercased() ?? ""
                let dateStr = session.startDate.formatted(date: .abbreviated, time: .shortened).lowercased()
                return label.contains(query) || dateStr.contains(query)
            }
        }

        if let timeFilter = activeTimeFilter {
            let cal = Calendar.current
            switch timeFilter {
            case .thisWeek:
                let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                result = result.filter { $0.startDate >= cutoff }
            case .thisMonth:
                let cutoff = cal.date(byAdding: .month, value: -1, to: Date()) ?? Date()
                result = result.filter { $0.startDate >= cutoff }
            }
        } else if useCustomRange {
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: customEndDate) ?? customEndDate
            result = result.filter { $0.startDate >= customStartDate && $0.startDate < endOfDay }
        }

        if let durationFilter = activeDurationFilter {
            result = result.filter { durationFilter.matches($0.durationSeconds) }
        }

        return result
    }

    private func clearAllFilters() {
        searchText = ""
        activeTimeFilter = nil
        activeDurationFilter = nil
        useCustomRange = false
    }

    var body: some View {
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
            List(selection: $selection) {
                // Aggregate stats + smoothness trend
                if !isFiltering {
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
                }

                // Trips section (hidden while searching/filtering)
                if !isFiltering && !trips.isEmpty {
                    Section {
                        ForEach(trips) { trip in
                            NavigationLink(destination: TripView(trip: trip)) {
                                TripCardView(trip: trip)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { modelContext.delete(trips[$0]) }
                        }
                    } header: {
                        Text("Trips")
                            .font(.footnote).fontWeight(.medium)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .tracking(0.3)
                    }
                }

                // Filter chips
                Section {
                    FilterChipRow(
                        activeTimeFilter: $activeTimeFilter,
                        activeDurationFilter: $activeDurationFilter,
                        useCustomRange: $useCustomRange,
                        showDateRangePicker: $showDateRangePicker
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }

                // Drive cards
                Section {
                    if filteredSessions.isEmpty {
                        VStack(spacing: 14) {
                            ContentUnavailableView(
                                "No results",
                                systemImage: "magnifyingglass",
                                description: Text("No drives match your search or filters.")
                            )
                            Button("Clear Filters") {
                                clearAllFilters()
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.bottom, 8)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    } else {
                        ForEach(filteredSessions) { session in
                            NavigationLink(destination: DriveSessionView(session: session)) {
                                SessionCardView(session: session)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            .contextMenu {
                                if let existingTrip = session.trip {
                                    Button(role: .destructive) {
                                        session.trip = nil
                                        try? modelContext.save()
                                    } label: {
                                        Label("Remove from \"\(existingTrip.name)\"",
                                              systemImage: "minus.circle")
                                    }
                                } else if !trips.isEmpty {
                                    Menu("Add to Trip") {
                                        ForEach(trips) { trip in
                                            Button(trip.name) {
                                                session.trip = trip
                                                try? modelContext.save()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { modelContext.delete(filteredSessions[$0]) }
                        }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Text(isFiltering ? "Results" : "Recent Drives")
                            .font(.footnote).fontWeight(.medium)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .tracking(0.3)
                        if isFiltering {
                            Text("(\(filteredSessions.count))")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
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

// MARK: - Filter chip row

private struct FilterChipRow: View {
    @Binding var activeTimeFilter: TimeFilter?
    @Binding var activeDurationFilter: DurationFilter?
    @Binding var useCustomRange: Bool
    @Binding var showDateRangePicker: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimeFilter.allCases, id: \.self) { filter in
                    FilterChip(label: filter.rawValue, isActive: activeTimeFilter == filter) {
                        if activeTimeFilter == filter {
                            activeTimeFilter = nil
                        } else {
                            activeTimeFilter = filter
                            useCustomRange = false
                        }
                    }
                }

                FilterChip(
                    label: "Custom Range",
                    isActive: useCustomRange,
                    systemImage: "calendar"
                ) {
                    showDateRangePicker = true
                }

                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)

                ForEach(DurationFilter.allCases, id: \.self) { filter in
                    FilterChip(label: filter.rawValue, isActive: activeDurationFilter == filter) {
                        activeDurationFilter = activeDurationFilter == filter ? nil : filter
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let label: String
    let isActive: Bool
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isActive ? Color.accentColor : Color(.secondarySystemGroupedBackground),
                in: Capsule()
            )
            .foregroundStyle(isActive ? Color.white : Color(.label))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

// MARK: - Date range picker sheet

private struct DateRangePickerSheet: View {
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var isPresented: Bool
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
            }
            .navigationTitle("Custom Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        onApply()
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Drive card row

private struct SessionCardView: View {
    let session: DriveSession
    @AppStorage("ds.showDrivingScore") private var showDrivingScore = true
    @AppStorage("ds.geoLabels") private var geoLabels = true

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

    private var primaryLabel: String {
        if geoLabels, let label = session.routeLabel { return label }
        return session.startDate.formatted(date: .abbreviated, time: .shortened)
    }

    private var timeRange: String {
        let end = session.startDate.addingTimeInterval(session.durationSeconds)
        let fmt = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(session.startDate.formatted(fmt)) → \(end.formatted(fmt))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if session.routePoints.count >= 2 {
                    RouteMapView(track: thumbnailTrack, peakEvents: [], thumbnailMode: true,
                                 trackColor: session.driveMode.uiColor)
                        .allowsHitTesting(false)
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 76, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(primaryLabel)
                                .font(.system(size: 14.5, weight: .semibold))
                                .lineLimit(1)
                            if session.driveMode != .normal {
                                Label(session.driveMode.label, systemImage: session.driveMode.sfSymbol)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(session.driveMode.color)
                                    .labelStyle(.iconOnly)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(session.driveMode.color.opacity(0.12), in: Capsule())
                            }
                        }
                        if geoLabels && session.routeLabel != nil {
                            Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Text(timeRange)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if showDrivingScore && session.driveMode.receivesScore {
                        ScoreRing(value: score, size: 34)
                    }
                }

                HStack(spacing: 12) {
                    Text(formatDistance(session.totalDistanceM))
                    Text(formatDuration(session.durationSeconds))
                    if session.driveMode.receivesScore {
                        Text("\(Int(session.maxSpeedMps * 3.6)) km/h")
                            .foregroundStyle(Color.accentColor)
                        Text(String(format: "%.2f g", session.peakNetAccel))
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if session.driveMode.receivesScore {
                    let hardTotal = session.hardAccelCount + session.hardBrakingCount + session.hardCorneringCount
                    Text("\(hardTotal) hard event\(hardTotal == 1 ? "" : "s") logged")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Route only — no score")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
