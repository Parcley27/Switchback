//
//  SurfaceMapView.swift
//  DriverStats
//

import MapKit
import SwiftUI

// MARK: - Pre-computed per-session roughness data

private struct SessionRoughnessData: Sendable {
    let coords: [CLLocationCoordinate2D]
    let roughness: [Float]   // one value per coord; 0 = no event nearby, >0 = g-force
}

// MARK: - Top-level SwiftUI wrapper

struct SurfaceMapView: View {
    let sessions: [DriveSession]

    @State private var polylineData: [SessionRoughnessData] = []

    // Cheap scalar signature: changes when surface events are recomputed or routes change
    private var sessionsSignature: Int {
        sessions.reduce(0) { acc, s in
            acc &+ s.surfaceEventCount &+ Int(s.totalDistanceM)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            SurfaceMapRepresentable(polylineData: polylineData)

            legendPanel
        }
        .task(id: sessionsSignature) {
            // Extract SwiftData objects on the main actor into plain Sendable types
            let sources: [(lats: [Double], lons: [Double],
                           eLats: [Double], eLons: [Double], eGs: [Double])] = sessions.map { s in
                let lats  = s.routeLatitudes
                let lons  = s.routeLongitudes
                let evts  = s.peakEventsRestored.filter { $0.type == .surface }
                let eLats = evts.map { $0.coordinate.latitude }
                let eLons = evts.map { $0.coordinate.longitude }
                let eGs   = evts.map { Double($0.formatted.components(separatedBy: " ").first ?? "0") ?? 0 }
                return (lats, lons, eLats, eLons, eGs)
            }

            // Heavy computation on a background thread
            let built: [SessionRoughnessData] = await Task.detached(priority: .userInitiated) {
                let searchDeg = 80.0 / 111_000.0  // ~80 m search radius in degrees
                return sources.compactMap { src -> SessionRoughnessData? in
                    guard src.lats.count >= 2, src.lats.count == src.lons.count else { return nil }
                    let step = max(1, src.lats.count / 250)
                    var coords   = [CLLocationCoordinate2D]()
                    var roughness = [Float]()
                    for i in stride(from: 0, to: src.lats.count, by: step) {
                        let lat = src.lats[i], lon = src.lons[i]
                        coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        // Find the worst surface event within the search radius
                        var maxG = 0.0
                        for j in 0..<src.eLats.count {
                            let dlat = lat - src.eLats[j]
                            let dlon = lon - src.eLons[j]
                            if abs(dlat) < searchDeg && abs(dlon) < searchDeg {
                                maxG = max(maxG, src.eGs[j])
                            }
                        }
                        roughness.append(Float(maxG))
                    }
                    return SessionRoughnessData(coords: coords, roughness: roughness)
                }
            }.value

            polylineData = built
        }
    }

    // MARK: - Legend

    private var legendPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Road Roughness")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                legendSwatch(.systemBlue,   "Smooth / no data")
                legendSwatch(.systemYellow, "Mild")
                legendSwatch(.systemOrange, "Moderate")
                legendSwatch(.systemRed,    "Severe")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private func legendSwatch(_ color: UIColor, _ label: String) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(Color(color))
                .frame(width: 18, height: 5)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - UIViewRepresentable

private struct SurfaceMapRepresentable: UIViewRepresentable {
    let polylineData: [SessionRoughnessData]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(map: map, polylineData: polylineData)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var lastCount = -1
        // polyline object ID → roughness array for that polyline
        private var roughnessForPolyline: [ObjectIdentifier: [Float]] = [:]

        func update(map: MKMapView, polylineData: [SessionRoughnessData]) {
            guard polylineData.count != lastCount else { return }
            lastCount = polylineData.count

            map.removeOverlays(map.overlays)
            roughnessForPolyline.removeAll()

            var unionRect = MKMapRect.null
            for data in polylineData {
                guard data.coords.count >= 2 else { continue }
                let poly = MKPolyline(coordinates: data.coords, count: data.coords.count)
                roughnessForPolyline[ObjectIdentifier(poly)] = data.roughness
                map.addOverlay(poly, level: .aboveRoads)
                unionRect = unionRect.union(poly.boundingMapRect)
            }

            guard !unionRect.isNull else { return }
            map.setVisibleMapRect(
                unionRect,
                edgePadding: UIEdgeInsets(top: 60, left: 24, bottom: 200, right: 24),
                animated: false
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let roughness = roughnessForPolyline[ObjectIdentifier(polyline)] ?? []
            let hasEvents = roughness.contains { $0 > 0.01 }

            guard hasEvents else {
                // Pure smooth route: single flat colour is much cheaper to render than gradient
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.45)
                r.lineWidth   = 4
                r.lineCap     = .round
                return r
            }

            let renderer = MKGradientPolylineRenderer(polyline: polyline)
            renderer.lineWidth  = 5
            renderer.lineCap    = .round
            renderer.lineJoin   = .round

            var colors    = [UIColor]()
            var locations = [CGFloat]()
            for i in 0..<polyline.pointCount {
                locations.append(CGFloat(polyline.location(atPointIndex: i)))
                let g = i < roughness.count ? Double(roughness[i]) : 0
                colors.append(roughnessColor(g))
            }
            renderer.setColors(colors, locations: locations)
            return renderer
        }

        // No event / smooth → blue; mild → yellow; moderate → orange; severe → red
        private func roughnessColor(_ g: Double) -> UIColor {
            if g < 0.05  { return UIColor.systemBlue.withAlphaComponent(0.45) }
            if g < 0.40  { return UIColor.systemGreen.withAlphaComponent(0.85) }
            if g < 0.55  { return UIColor.systemYellow.withAlphaComponent(0.90) }
            if g < 0.70  { return UIColor.systemOrange.withAlphaComponent(0.90) }
            return          UIColor.systemRed.withAlphaComponent(0.90)
        }
    }
}
