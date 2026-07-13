//
//  AllDrivesMapView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 6/27/26.
//

import MapKit
import SwiftUI

struct AllDrivesMapView: UIViewRepresentable {
    let sessions: [DriveSession]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(map: map, sessions: sessions)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var sessionIDs: Set<ObjectIdentifier> = []
        private var sessions: [DriveSession] = []
        // session object ID → current polyline on the map
        private var polylineForSession: [ObjectIdentifier: MKPolyline] = [:]
        // session object ID → stride currently rendered
        private var strideForSession: [ObjectIdentifier: Int] = [:]
        // polyline object ID → session (fast renderer lookup)
        private var sessionForPolyline: [ObjectIdentifier: DriveSession] = [:]

        func update(map: MKMapView, sessions: [DriveSession]) {
            let newIDs = Set(sessions.map { ObjectIdentifier($0) })
            guard newIDs != sessionIDs else { return }

            self.sessions = sessions
            self.sessionIDs = newIDs

            map.removeOverlays(map.overlays)
            polylineForSession.removeAll()
            strideForSession.removeAll()
            sessionForPolyline.removeAll()

            // Use a large overview span for the initial lightweight render;
            // regionDidChangeAnimated fires after setVisibleMapRect and immediately
            // upgrades fidelity to match the actual viewport.
            let overviewSpan = MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
            var unionRect = MKMapRect.null
            for session in sessions {
                if let poly = addPolyline(for: session, on: map, span: overviewSpan) {
                    unionRect = unionRect.union(poly.boundingMapRect)
                }
            }

            guard !unionRect.isNull else { return }
            map.setVisibleMapRect(
                unionRect,
                edgePadding: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20),
                animated: false
            )
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateFidelity(map: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            let session = sessionForPolyline[ObjectIdentifier(polyline)]
            let strokeColor: UIColor
            if let session = session, session.driveMode != .normal {
                strokeColor = session.driveMode.uiColor.withAlphaComponent(0.8)
            } else {
                let score = session?.smoothnessScore ?? 50
                strokeColor = scoreColor(score).withAlphaComponent(0.66)
            }
            renderer.strokeColor = strokeColor
            renderer.lineWidth = 8
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        // MARK: Private helpers

        @discardableResult
        private func addPolyline(for session: DriveSession, on map: MKMapView, span: MKCoordinateSpan) -> MKPolyline? {
            let totalPoints = session.routeLatitudes.count
            guard totalPoints >= 2 else { return nil }

            let step = computeStep(totalPoints: totalPoints, span: span)
            let pts = session.routePoints
            let sampled = Swift.stride(from: 0, to: pts.count, by: step).map { pts[$0] }
            let coords = sampled.map(\.coordinate)
            let polyline = MKPolyline(coordinates: coords, count: coords.count)

            let sid = ObjectIdentifier(session)
            polylineForSession[sid] = polyline
            strideForSession[sid] = step
            sessionForPolyline[ObjectIdentifier(polyline)] = session
            map.addOverlay(polyline, level: .aboveRoads)
            return polyline
        }

        private func updateFidelity(map: MKMapView) {
            let visibleRect = map.visibleMapRect
            let span = map.region.span

            for session in sessions {
                let sid = ObjectIdentifier(session)
                guard let currentPolyline = polylineForSession[sid],
                      visibleRect.intersects(currentPolyline.boundingMapRect) else { continue }

                let totalPoints = session.routeLatitudes.count
                guard totalPoints >= 2 else { continue }

                let newStep = computeStep(totalPoints: totalPoints, span: span)
                guard newStep != strideForSession[sid] else { continue }

                sessionForPolyline.removeValue(forKey: ObjectIdentifier(currentPolyline))
                map.removeOverlay(currentPolyline)
                addPolyline(for: session, on: map, span: span)
            }
        }

        // Proportional stride: target = max(minFloor, totalPoints / proportionalDivisor).
        // Longer drives get more rendered points at every zoom level; the minFloor
        // ensures short drives still look smooth when zoomed in.
        //
        // Example at 0.01° span (neighborhood):
        //   500-pt drive  → target = max(180, 83)  = 180, step = 2
        //   5000-pt drive → target = max(180, 833) = 833, step = 6
        private func computeStep(totalPoints: Int, span: MKCoordinateSpan) -> Int {
            let deg = max(span.latitudeDelta, span.longitudeDelta)
            let proportionalDivisor: Int
            let minFloor: Int
            if deg < 0.005 {
                proportionalDivisor = 4;  minFloor = 250
            } else if deg < 0.01 {
                proportionalDivisor = 6;  minFloor = 180
            } else if deg < 0.05 {
                proportionalDivisor = 12; minFloor = 100
            } else if deg < 0.2 {
                proportionalDivisor = 25; minFloor = 60
            } else {
                proportionalDivisor = 50; minFloor = 40
            }
            let target = max(minFloor, totalPoints / proportionalDivisor)
            return max(1, totalPoints / target)
        }

        // Red → orange → yellow → green ramp mapping score 0–100
        private func scoreColor(_ score: Double) -> UIColor {
            let t = CGFloat(max(0, min(1, score / 100.0)))
            let hue: CGFloat
            if t < 1/3 {
                hue = t * 3 * (30.0 / 360.0)
            } else if t < 2/3 {
                hue = 30.0/360.0 + (t - 1/3) * 3 * (30.0 / 360.0)
            } else {
                hue = 60.0/360.0 + (t - 2/3) * 3 * (60.0 / 360.0)
            }
            return UIColor(hue: hue, saturation: 1, brightness: 0.9, alpha: 1)
        }
    }
}
