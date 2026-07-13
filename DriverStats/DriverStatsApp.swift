//
//  DriverStatsApp.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import SwiftUI
import SwiftData

@main
struct DriverStatsApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            DriveSession.self,
            NamedLocation.self,
            Trip.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
