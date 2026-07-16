//
//  RouteThumbnail.swift
//  DriverStats
//

import CoreLocation
import CryptoKit
import MapKit
import SwiftUI

// MARK: - Snapshot cache (memory + disk)

final class RouteSnapshotCache {
    static let shared = RouteSnapshotCache()
    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 52_428_800  // 50 MB
    }

    private let memory = NSCache<NSString, UIImage>()

    private let diskDir: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("routeThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(for key: String) -> UIImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let url = diskURL(for: key),
              let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    func store(_ image: UIImage, for key: String) {
        memory.setObject(image, forKey: key as NSString)
        guard let url = diskURL(for: key), let data = image.pngData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clearAll() {
        memory.removeAllObjects()
        guard let dir = diskDir else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    var diskSizeBytes: Int {
        guard let dir = diskDir else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func diskURL(for key: String) -> URL? {
        let hash = SHA256.hash(data: Data(key.utf8))
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return diskDir?.appendingPathComponent("\(hex).png")
    }
}

// MARK: - Async snapshot builder

func makeRouteThumbnail(
    polylines: [(coords: [CLLocationCoordinate2D], color: UIColor)],
    size: CGSize,
    scale: CGFloat
) async -> UIImage? {
    let allCoords = polylines.flatMap(\.coords)
    guard allCoords.count >= 2 else { return nil }

    var minLat =  Double.infinity, maxLat = -Double.infinity
    var minLon =  Double.infinity, maxLon = -Double.infinity
    for c in allCoords {
        minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
        minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
    }

    let latSpan = max(maxLat - minLat, 0.0005)
    let lonSpan = max(maxLon - minLon, 0.0005)
    let pad = 0.15
    let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                       longitude: (minLon + maxLon) / 2),
        span: MKCoordinateSpan(latitudeDelta: latSpan * (1 + pad),
                               longitudeDelta: lonSpan * (1 + pad))
    )

    let opts = MKMapSnapshotter.Options()
    opts.size   = size
    opts.scale  = scale
    opts.mapType = .standard
    opts.pointOfInterestFilter = .excludingAll
    opts.showsBuildings = false
    opts.region = region

    guard let snapshot = try? await MKMapSnapshotter(options: opts).start() else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
        snapshot.image.draw(at: .zero)
        for poly in polylines {
            guard poly.coords.count >= 2 else { continue }
            let path = UIBezierPath()
            var first = true
            for coord in poly.coords {
                let pt = snapshot.point(for: coord)
                if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            }
            poly.color.setStroke()
            path.lineWidth = 3.5   // points; scale factor is applied by the renderer format
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

// MARK: - RouteThumbnailView

/// Displays a cached MKMapSnapshotter image for a single drive session.
/// Falls back to a placeholder while the snapshot is building.
struct RouteThumbnailView: View {
    let session: DriveSession
    var size: CGSize = CGSize(width: 76, height: 70)

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil

    private var cacheKey: String {
        // Scalar-only fields — no array materialization
        let t = Int(session.startDate.timeIntervalSinceReferenceDate)
        let d = Int(session.totalDistanceM)
        return "\(t)-\(d)-\(session.driveModeRaw)-\(Int(size.width))x\(Int(size.height))"
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(.tertiarySystemFill)
                    .overlay {
                        if session.totalDistanceM > 0 {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
            }
        }
        .task(id: cacheKey) {
            guard session.totalDistanceM > 0 else { return }
            if let cached = RouteSnapshotCache.shared.image(for: cacheKey) {
                image = cached; return
            }
            let lats  = session.routeLatitudes
            let lons  = session.routeLongitudes
            guard lats.count >= 2, lats.count == lons.count else { return }
            let step  = max(1, lats.count / 150)
            let coords = stride(from: 0, to: lats.count, by: step).map {
                CLLocationCoordinate2D(latitude: lats[$0], longitude: lons[$0])
            }
            let scale = displayScale
            let built = await makeRouteThumbnail(
                polylines: [(coords, session.driveMode.uiColor)],
                size: size, scale: scale)
            if let built {
                RouteSnapshotCache.shared.store(built, for: cacheKey)
                image = built
            }
        }
    }
}

// MARK: - TripThumbnailView

/// Displays a cached snapshot for all drives in a trip, each in their mode colour.
struct TripThumbnailView: View {
    let trip: Trip
    var size: CGSize = CGSize(width: 76, height: 70)

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage? = nil

    private var cacheKey: String {
        // Sorted so insertion order doesn't matter
        let sig = trip.sessions
            .map { "\(Int($0.startDate.timeIntervalSinceReferenceDate))" }
            .sorted().joined(separator: ",")
        return "trip-[\(sig)]-\(Int(size.width))x\(Int(size.height))"
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(.tertiarySystemFill)
                    .overlay {
                        if !trip.sessions.isEmpty {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
            }
        }
        .task(id: cacheKey) {
            guard !trip.sessions.isEmpty else { return }
            if let cached = RouteSnapshotCache.shared.image(for: cacheKey) {
                image = cached; return
            }
            var polylines: [(coords: [CLLocationCoordinate2D], color: UIColor)] = []
            for session in trip.orderedSessions {
                let lats = session.routeLatitudes
                let lons = session.routeLongitudes
                guard lats.count >= 2, lats.count == lons.count else { continue }
                let step = max(1, lats.count / 100)
                let coords = stride(from: 0, to: lats.count, by: step).map {
                    CLLocationCoordinate2D(latitude: lats[$0], longitude: lons[$0])
                }
                polylines.append((coords, session.driveMode.uiColor))
            }
            guard !polylines.isEmpty else { return }
            let scale = displayScale
            let built = await makeRouteThumbnail(polylines: polylines, size: size, scale: scale)
            if let built {
                RouteSnapshotCache.shared.store(built, for: cacheKey)
                image = built
            }
        }
    }
}
