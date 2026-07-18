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
    @State private var showingMapsView = false
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var showMergeConfirmation = false
    @State private var pendingNewTrip: Trip? = nil
    @State private var showingTripNamePrompt = false
    @State private var pendingTripName = ""
    @State private var quickTripSession: DriveSession? = nil

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
            selection: $selection,
            onNewTripFromSession: { session in
                quickTripSession = session
                pendingTripName = ""
                showingTripNamePrompt = true
            }
        )
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search drives…")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingMapsView = true
                } label: {
                    Image(systemName: "map")
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
                            pendingTripName = ""
                            showingTripNamePrompt = true
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
        .alert("Name This Trip", isPresented: $showingTripNamePrompt) {
            TextField("e.g. Road Trip, Daily Commute", text: $pendingTripName)
            Button("Create") { performCreateTrip() }
            Button("Cancel", role: .cancel) {}
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
        .fullScreenCover(isPresented: $showingMapsView) {
            NavigationStack {
                HistoryMapsView(sessions: sessions)
            }
        }
        .task {
            guard !surfaceEventsMigrated else { return }
            let threshold = (UserDefaults.standard.object(forKey: "ds.surfaceThreshold") as? Double) ?? 0.4
            let container = modelContext.container
            // Run on a background ModelContext so the main thread stays free
            await Task.detached(priority: .background) {
                let ctx = ModelContext(container)
                let descriptor = FetchDescriptor<DriveSession>()
                guard let all = try? ctx.fetch(descriptor) else { return }
                for session in all where !session.rawVert.isEmpty {
                    session.recomputeSurfaceEvents(threshold: threshold)
                }
                try? ctx.save()
            }.value
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
        let trimmed = pendingTripName.trimmingCharacters(in: .whitespaces)
        let trip = Trip(name: trimmed.isEmpty ? "Trip" : trimmed)
        modelContext.insert(trip)
        if let single = quickTripSession {
            single.trip = trip
            quickTripSession = nil
        } else {
            guard selection.count >= 2 else { return }
            let picked = sessions.filter { selection.contains($0.persistentModelID) }
            guard picked.count >= 2 else { return }
            for session in picked { session.trip = trip }
            selection.removeAll()
            withAnimation { editMode = .inactive }
        }
        try? modelContext.save()
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
    var onNewTripFromSession: (DriveSession) -> Void = { _ in }

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

    private struct DriveGroup {
        let header: String
        let sessions: [DriveSession]
    }

    private var driveGroups: [DriveGroup] {
        let cal = Calendar.current
        let now = Date()
        let weekCutoff = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let monthCutoff = cal.date(byAdding: .month, value: -1, to: now) ?? now
        var today: [DriveSession] = []
        var yesterday: [DriveSession] = []
        var thisWeek: [DriveSession] = []
        var thisMonth: [DriveSession] = []
        var older: [DriveSession] = []
        for session in filteredSessions {
            if cal.isDateInToday(session.startDate)        { today.append(session) }
            else if cal.isDateInYesterday(session.startDate) { yesterday.append(session) }
            else if session.startDate >= weekCutoff          { thisWeek.append(session) }
            else if session.startDate >= monthCutoff         { thisMonth.append(session) }
            else                                             { older.append(session) }
        }
        var groups: [DriveGroup] = []
        if !today.isEmpty     { groups.append(DriveGroup(header: "Today",      sessions: today)) }
        if !yesterday.isEmpty { groups.append(DriveGroup(header: "Yesterday",  sessions: yesterday)) }
        if !thisWeek.isEmpty  { groups.append(DriveGroup(header: "This Week",  sessions: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(DriveGroup(header: "This Month", sessions: thisMonth)) }
        if !older.isEmpty     { groups.append(DriveGroup(header: "Earlier",    sessions: older)) }
        return groups
    }

    @ViewBuilder
    private func driveRow(for session: DriveSession) -> some View {
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
            } else {
                Button {
                    onNewTripFromSession(session)
                } label: {
                    Label("New Trip…", systemImage: "plus.circle")
                }
                if !trips.isEmpty {
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
                // HistoryStatsHeader is Equatable; SwiftUI skips re-evaluation while
                // sessions are unchanged, so typing/filter/edit-mode changes don't
                // re-run the O(n) aggregate scans.
                if !isFiltering {
                    Section {
                        HistoryStatsHeader(sessions: sessions)
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

                // Drive cards — date-grouped when not filtering, flat when filtering
                if filteredSessions.isEmpty && isFiltering {
                    Section {
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
                    } header: {
                        HStack(spacing: 5) {
                            Text("Results")
                                .font(.footnote).fontWeight(.medium)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .tracking(0.3)
                            Text("(0)")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if isFiltering {
                    Section {
                        ForEach(filteredSessions) { session in
                            driveRow(for: session)
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { modelContext.delete(filteredSessions[$0]) }
                        }
                    } header: {
                        HStack(spacing: 5) {
                            Text("Results")
                                .font(.footnote).fontWeight(.medium)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .tracking(0.3)
                            Text("(\(filteredSessions.count))")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    ForEach(driveGroups, id: \.header) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                driveRow(for: session)
                            }
                            .onDelete { indexSet in
                                indexSet.forEach { modelContext.delete(group.sessions[$0]) }
                            }
                        } header: {
                            Text(group.header)
                                .font(.footnote).fontWeight(.medium)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .tracking(0.3)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
    }

}

// MARK: - Aggregate stats header
// Equatable so SwiftUI can skip re-evaluation when sessions haven't changed.
// Typing in the search bar, toggling filters, or changing edit selection do NOT
// alter the sessions array, so the aggregate scans and trend chart are bypassed.

private struct HistoryStatsHeader: View, Equatable {
    let sessions: [DriveSession]

    static func == (lhs: HistoryStatsHeader, rhs: HistoryStatsHeader) -> Bool {
        guard lhs.sessions.count == rhs.sessions.count else { return false }
        return zip(lhs.sessions, rhs.sessions).allSatisfy { $0 === $1 }
    }

    // MARK: Cache

    private var statsKey: String { StatsCache.key(for: sessions) }

    private var stats: CachedStats {
        if let cached = StatsCache.shared.load(key: statsKey) { return cached }
        let built = CachedStats.build(from: sessions)
        StatsCache.shared.save(built, key: statsKey)
        return built
    }

    // Computed live — time-relative, stale if cached across day boundaries
    private var thisWeekKm: Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions.filter { $0.startDate > cutoff }.reduce(0) { $0 + $1.totalDistanceM } / 1000
    }

    // Normal drives from the last 7 days, chronological — drives not scored aren't in the trend
    private var weeklyNormalTrend: [DriveSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions
            .filter { $0.driveMode == .normal && $0.startDate >= cutoff }
            .sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
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
                         value: String(format: "%.0f", stats.avgScore),
                         accent: true)
                StatCell(label: "Best peak",
                         value: String(format: "%.2f", stats.bestPeakNet),
                         unit: "g")
                StatCell(label: "All drives",
                         value: "\(sessions.count)")
                StatCell(label: "This week",
                         value: String(format: "%.0f", thisWeekKm),
                         unit: "km")
                StatCell(label: "Total dist",
                         value: String(format: "%.0f", stats.totalDistanceM / 1000),
                         unit: "km")
                StatCell(label: "Total time",
                         value: formatTotalDrivingTime(stats.totalDurationSeconds))
            }

            if weeklyNormalTrend.count >= 3 {
                CardSection("Smoothness trend",
                            note: "last 7 days",
                            innerPadding: 12) {
                    Chart {
                        ForEach(Array(weeklyNormalTrend.enumerated()), id: \.offset) { i, session in
                            AreaMark(x: .value("Drive", i + 1), y: .value("Score", session.smoothnessScore))
                                .foregroundStyle(Color.accentColor.opacity(0.12))
                            LineMark(x: .value("Drive", i + 1), y: .value("Score", session.smoothnessScore))
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
                        AxisMarks(values: .automatic(desiredCount: min(weeklyNormalTrend.count, 8))) {
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 90)
                }
            }
        }
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

    private var score: Int { Int(session.smoothnessScore) }

    private var primaryLabel: String {
        if geoLabels, let label = session.routeLabel { return label }
        return session.startDate.formatted(date: .abbreviated, time: .shortened)
    }

    private var timeRange: String {
        let end = session.startDate.addingTimeInterval(session.durationSeconds)
        let fmt = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(session.startDate.formatted(fmt)) – \(end.formatted(fmt))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                RouteThumbnailView(session: session)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(primaryLabel)
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if geoLabels && session.routeLabel != nil {
                            Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }

                        Text(timeRange)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 8)

                    if session.driveMode == .normal {
                        if showDrivingScore {
                            ScoreRing(value: score, size: 42)
                        }
                    } else {
                        DriveModeCircle(mode: session.driveMode)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
                .padding(.top, 10)

            HStack(spacing: 0) {
                DriveStatPill(systemImage: "arrow.left.and.right", label: formatDistance(session.totalDistanceM))
                Spacer()
                DriveStatPill(systemImage: "clock", label: formatDuration(session.durationSeconds))
                if session.driveMode.receivesScore {
                    Spacer()
                    DriveStatPill(systemImage: "speedometer", label: "\(Int(session.maxSpeedMps * 3.6)) km/h")
                }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Drive mode circle (replaces score ring for non-normal drives)

private struct DriveModeCircle: View {
    let mode: DriveMode
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemFill), lineWidth: 4.5)
            Circle()
                .stroke(mode.color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            Image(systemName: mode.sfSymbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(mode.color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Combined map view (All Drives / Road Surface toggle)

private struct HistoryMapsView: View {
    let sessions: [DriveSession]
    @Environment(\.dismiss) private var dismiss

    enum MapMode: String, CaseIterable {
        case drives  = "Drives"
        case surface = "Surface"
    }

    @State private var mode: MapMode = .drives

    var body: some View {
        Group {
            if mode == .drives {
                AllDrivesMapView(sessions: sessions)
            } else {
                SurfaceMapView(sessions: sessions)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Map mode", selection: $mode) {
                    ForEach(MapMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}
