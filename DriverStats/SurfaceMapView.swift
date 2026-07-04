//
//  SurfaceMapView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 6/30/26.
//

import MapKit
import SwiftUI

// MARK: - Cluster model

private struct SurfaceCluster {
    let coordinate: CLLocationCoordinate2D
    let count: Int
    let maxGForce: Double
}

// MARK: - Top-level SwiftUI wrapper

struct SurfaceMapView: View {
    let sessions: [DriveSession]
    @State private var showRoutes = false

    private var clusters: [SurfaceCluster] {
        let cellDeg = 50.0 / 111_000.0
        var cells: [SIMD2<Int>: [(CLLocationCoordinate2D, Double)]] = [:]
        for session in sessions {
            for event in session.peakEventsRestored where event.type == .surface {
                let key = SIMD2<Int>(
                    Int(floor(event.coordinate.latitude  / cellDeg)),
                    Int(floor(event.coordinate.longitude / cellDeg))
                )
                let gVal = Double(event.formatted.components(separatedBy: " ").first ?? "0") ?? 0
                cells[key, default: []].append((event.coordinate, gVal))
            }
        }
        return cells.values.compactMap { items -> SurfaceCluster? in
            guard !items.isEmpty else { return nil }
            let lat  = items.map(\.0.latitude).reduce(0,  +) / Double(items.count)
            let lon  = items.map(\.0.longitude).reduce(0, +) / Double(items.count)
            let maxG = items.map(\.1).max() ?? 0.4
            return SurfaceCluster(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                count: items.count,
                maxGForce: maxG
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            SurfaceMapRepresentable(clusters: clusters, sessions: showRoutes ? sessions : [])

            controlPanel
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $showRoutes) {
                Label("Show drive routes", systemImage: "arrow.triangle.turn.up.right.circle")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .tint(.accentColor)

            gForceLegend
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private var gForceLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Severity (g-force)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("mild")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                LinearGradient(
                    colors: [.green, .yellow, .orange, .red],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 6)
                .clipShape(Capsule())
                Text("severe")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - UIViewRepresentable

private struct SurfaceMapRepresentable: UIViewRepresentable {
    let clusters: [SurfaceCluster]
    let sessions: [DriveSession]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(map: map, clusters: clusters, sessions: sessions)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var renderedClusterCount = -1
        private var renderedSessionCount = -1
        private var circleColors: [ObjectIdentifier: Double] = [:]

        func update(map: MKMapView, clusters: [SurfaceCluster], sessions: [DriveSession]) {
            guard clusters.count != renderedClusterCount || sessions.count != renderedSessionCount else { return }
            renderedClusterCount = clusters.count
            renderedSessionCount = sessions.count

            map.removeOverlays(map.overlays)
            circleColors.removeAll()

            // Add route polylines underneath surface circles
            for session in sessions {
                let pts = session.routePoints
                guard pts.count >= 2 else { continue }
                let step = max(1, pts.count / 200)
                let coords = Swift.stride(from: 0, to: pts.count, by: step).map { pts[$0].coordinate }
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                map.addOverlay(polyline, level: .aboveRoads)
            }

            // Add surface event circles on top
            var unionRect = MKMapRect.null
            for cluster in clusters {
                let radius = max(20.0, min(60.0, Double(cluster.count) * 8 + 12))
                let circle = MKCircle(center: cluster.coordinate, radius: radius)
                circleColors[ObjectIdentifier(circle)] = cluster.maxGForce
                map.addOverlay(circle, level: .aboveLabels)
                unionRect = unionRect.union(circle.boundingMapRect)
            }

            guard !unionRect.isNull else { return }
            map.setVisibleMapRect(
                unionRect,
                edgePadding: UIEdgeInsets(top: 60, left: 24, bottom: 220, right: 24),
                animated: false
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                let g = circleColors[ObjectIdentifier(circle)] ?? 0.4
                let col = severityColor(g)
                renderer.fillColor   = col.withAlphaComponent(0.5)
                renderer.strokeColor = col.withAlphaComponent(0.9)
                renderer.lineWidth   = 1.5
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35)
                renderer.lineWidth   = 3
                renderer.lineCap     = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // Green (mild ~0.4 g) → yellow → orange → red (severe 0.8+ g)
        private func severityColor(_ g: Double) -> UIColor {
            let t = CGFloat(max(0, min(1, (g - 0.4) / 0.6)))
            let hue: CGFloat
            if t < 0.33 {
                hue = 120.0/360.0 - t / 0.33 * 60.0/360.0
            } else if t < 0.66 {
                hue = 60.0/360.0 - (t - 0.33) / 0.33 * 30.0/360.0
            } else {
                hue = 30.0/360.0 - (t - 0.66) / 0.34 * 30.0/360.0
            }
            return UIColor(hue: max(0, hue), saturation: 1, brightness: 0.85, alpha: 1)
        }
    }
}
