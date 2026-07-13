//
//  RouteMapView.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import MapKit
import SwiftUI

// MARK: - Custom annotation carrying a PeakEvent

final class PeakAnnotation: NSObject, MKAnnotation {
    let event: PeakEvent
    var coordinate: CLLocationCoordinate2D { event.coordinate }
    var title: String? { event.type.title }
    var subtitle: String? { event.formatted }
    init(_ event: PeakEvent) { self.event = event }
}

// MARK: - Scrub position annotation

final class ScrubAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ coord: CLLocationCoordinate2D) { self.coordinate = coord }
}

// MARK: - Map view

struct RouteMapView: UIViewRepresentable {
    let track: [RoutePoint]
    var peakEvents: [PeakEvent] = []
    var thumbnailMode: Bool = false
    var showSurfaceEvents: Bool = false
    var scrubCoordinate: CLLocationCoordinate2D? = nil
    /// When set, overrides the speed-gradient with a flat colour (used for non-normal drive modes).
    /// In thumbnail mode, this replaces the default systemBlue.
    var trackColor: UIColor? = nil
    /// Called with a 0–1 fraction when the user long-presses and drags along the route,
    /// or nil when the gesture ends. Ignored in thumbnailMode.
    var onScrubFractionChanged: ((Double?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: "scrub")

        // Long-press + drag to scrub the route
        let scrubGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleScrubGesture(_:)))
        scrubGesture.minimumPressDuration = 0.25
        scrubGesture.allowableMovement = 10_000   // allow free movement after press fires
        map.addGestureRecognizer(scrubGesture)

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onScrubFractionChanged = onScrubFractionChanged
        context.coordinator.trackColor = trackColor
        context.coordinator.setup(map: map, track: track, peakEvents: peakEvents,
                                  thumbnailMode: thumbnailMode, showSurfaceEvents: showSurfaceEvents)
        context.coordinator.updateScrub(map: map, coordinate: scrubCoordinate)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        private var fullTrack: [RoutePoint] = []
        private var currentStride: Int = 1
        private var lastTrackSignature: Int = -1
        private var lastPeakEventCount: Int = -1
        private var lastShowSurfaceEvents: Bool = false
        var trackColor: UIColor? = nil
        private(set) var thumbnailMode: Bool = false
        // parallel to the polyline currently on the map
        var speedsAtPoints: [Double] = []

        private var scrubAnnotation: ScrubAnnotation? = nil
        var onScrubFractionChanged: ((Double?) -> Void)? = nil

        // Surface event circle overlays and their associated g-forces for coloring
        private var circleColors: [ObjectIdentifier: Double] = [:]

        func setup(map: MKMapView, track: [RoutePoint], peakEvents: [PeakEvent],
                   thumbnailMode: Bool, showSurfaceEvents: Bool) {
            let sig = trackSignature(track, thumbnail: thumbnailMode)
            let trackChanged = sig != lastTrackSignature
            let eventsChanged = peakEvents.count != lastPeakEventCount
            let surfaceToggled = showSurfaceEvents != lastShowSurfaceEvents
            guard trackChanged || eventsChanged || surfaceToggled else { return }

            lastTrackSignature = sig
            lastPeakEventCount = peakEvents.count
            lastShowSurfaceEvents = showSurfaceEvents
            self.thumbnailMode = thumbnailMode
            self.fullTrack = track

            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            // scrubAnnotation was on the map; updateScrub will re-add it after setup returns
            scrubAnnotation = nil
            circleColors.removeAll()
            guard track.count >= 2 else { return }

            // Non-surface peak event markers
            for event in peakEvents where event.type != .surface {
                map.addAnnotation(PeakAnnotation(event))
            }

            // Route polyline (added first so circles render on top)
            if thumbnailMode {
                placePolyline(sampled: track, on: map)
            } else {
                // Use a large span so the first render is cheap; regionDidChangeAnimated
                // fires right after setVisibleMapRect and upgrades to proper fidelity.
                placePolyline(span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10), on: map)
            }

            // Surface event circles (grouped to 25 m cells)
            // aboveLabels ensures circles render on top of the gradient polyline regardless of zoom
            if showSurfaceEvents && !thumbnailMode {
                let surfaceEvents = peakEvents.filter { $0.type == .surface }
                for (coord, count, maxG) in clusterEvents(surfaceEvents, cellMeters: 25) {
                    let radius = max(18.0, min(50.0, Double(count) * 6 + 14))
                    let circle = MKCircle(center: coord, radius: radius)
                    circleColors[ObjectIdentifier(circle)] = maxG
                    map.addOverlay(circle, level: .aboveLabels)
                }
            }

            let padding: UIEdgeInsets = thumbnailMode
                ? UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
                : UIEdgeInsets(top: 60, left: 40, bottom: 40, right: 40)
            // Use the first overlay (the polyline) for bounding rect
            if let overlay = map.overlays.first {
                map.setVisibleMapRect(overlay.boundingMapRect, edgePadding: padding, animated: false)
            }
        }

        func updateScrub(map: MKMapView, coordinate: CLLocationCoordinate2D?) {
            if let coord = coordinate {
                if let existing = scrubAnnotation {
                    existing.coordinate = coord
                } else {
                    let ann = ScrubAnnotation(coord)
                    scrubAnnotation = ann
                    map.addAnnotation(ann)
                }
            } else if let existing = scrubAnnotation {
                map.removeAnnotation(existing)
                scrubAnnotation = nil
            }
        }

        // MARK: - Route scrub gesture

        @objc func handleScrubGesture(_ gesture: UILongPressGestureRecognizer) {
            guard !thumbnailMode, !fullTrack.isEmpty,
                  let map = gesture.view as? MKMapView else { return }

            switch gesture.state {
            case .began, .changed:
                let touchPoint = gesture.location(in: map)
                let coord = map.convert(touchPoint, toCoordinateFrom: map)
                // Find nearest route point by squared lat/lon distance (fast, accurate enough)
                var bestIdx = 0
                var bestDist = Double.infinity
                for (i, pt) in fullTrack.enumerated() {
                    let dlat = pt.coordinate.latitude - coord.latitude
                    let dlon = pt.coordinate.longitude - coord.longitude
                    let d = dlat * dlat + dlon * dlon
                    if d < bestDist { bestDist = d; bestIdx = i }
                }
                let frac = Double(bestIdx) / Double(max(1, fullTrack.count - 1))
                onScrubFractionChanged?(frac)
            case .ended, .cancelled, .failed:
                onScrubFractionChanged?(nil)
            default:
                break
            }
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !thumbnailMode, fullTrack.count >= 2 else { return }
            let newStep = computeStep(totalPoints: fullTrack.count, span: mapView.region.span)
            guard newStep != currentStride else { return }
            // Only remove polylines — surface circle overlays stay in place
            let polylines = mapView.overlays.compactMap { $0 as? MKPolyline }
            mapView.removeOverlays(polylines)
            placePolyline(span: mapView.region.span, on: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                let g = circleColors[ObjectIdentifier(circle)] ?? 0.4
                let col = severityColor(g)
                renderer.fillColor   = col.withAlphaComponent(0.55)
                renderer.strokeColor = col.withAlphaComponent(0.95)
                renderer.lineWidth   = 2
                return renderer
            }
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            if thumbnailMode {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = trackColor ?? UIColor.systemBlue
                renderer.lineWidth = 2
                renderer.lineCap = .round
                return renderer
            }

            // Flat colour override for non-normal drive modes
            if let flatColor = trackColor {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = flatColor
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            let renderer = MKGradientPolylineRenderer(polyline: polyline)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round

            let maxSpeed = max(speedsAtPoints.max() ?? 1.0, 0.01)
            var colors = [UIColor]()
            var locations = [CGFloat]()
            for i in 0..<polyline.pointCount {
                locations.append(CGFloat(polyline.location(atPointIndex: i)))
                let speed = i < speedsAtPoints.count ? speedsAtPoints[i] : 0
                colors.append(color(forSpeedMps: speed, maxMps: maxSpeed))
            }
            renderer.setColors(colors, locations: locations)
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is ScrubAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "scrub", for: annotation) as! MKMarkerAnnotationView
                view.annotation = annotation
                view.canShowCallout = false
                view.animatesWhenAdded = false
                view.markerTintColor = .systemBlue
                view.glyphText = "●"
                return view
            }
            guard let peakAnn = annotation as? PeakAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier,
                for: annotation) as! MKMarkerAnnotationView
            view.annotation = annotation
            view.canShowCallout = true
            view.glyphImage = UIImage(systemName: peakAnn.event.type.sfSymbol)
            switch peakAnn.event.type {
            case .maxSpeed:    view.markerTintColor = .systemGreen
            case .peakAccel:   view.markerTintColor = .systemBlue
            case .peakBraking: view.markerTintColor = .systemRed
            case .peakRight, .peakLeft: view.markerTintColor = .systemOrange
            case .surface:     view.markerTintColor = .systemYellow
            }
            return view
        }

        // MARK: Private helpers

        private func placePolyline(span: MKCoordinateSpan, on map: MKMapView) {
            let step = computeStep(totalPoints: fullTrack.count, span: span)
            currentStride = step
            let sampled = Swift.stride(from: 0, to: fullTrack.count, by: step).map { fullTrack[$0] }
            placePolyline(sampled: sampled, on: map)
        }

        private func placePolyline(sampled: [RoutePoint], on map: MKMapView) {
            let coords = sampled.map(\.coordinate)
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            speedsAtPoints = sampled.map(\.speedMps)
            map.addOverlay(polyline, level: .aboveRoads)
        }

        private func computeStep(totalPoints: Int, span: MKCoordinateSpan) -> Int {
            let deg = max(span.latitudeDelta, span.longitudeDelta)
            let divisor: Int
            let floor: Int
            if deg < 0.005 {
                divisor = 4;  floor = 250
            } else if deg < 0.01 {
                divisor = 6;  floor = 180
            } else if deg < 0.05 {
                divisor = 12; floor = 100
            } else if deg < 0.2 {
                divisor = 25; floor = 60
            } else {
                divisor = 50; floor = 40
            }
            let target = max(floor, totalPoints / divisor)
            return max(1, totalPoints / target)
        }

        private func trackSignature(_ track: [RoutePoint], thumbnail: Bool) -> Int {
            var hasher = Hasher()
            hasher.combine(track.count)
            hasher.combine(thumbnail)
            if let first = track.first {
                hasher.combine(first.coordinate.latitude)
                hasher.combine(first.coordinate.longitude)
            }
            return hasher.finalize()
        }

        // Cluster surface events into grid cells of `cellMeters` side length.
        // Returns (centroid, count, maxGForce) per cell.
        private func clusterEvents(_ events: [PeakEvent], cellMeters: Double)
            -> [(CLLocationCoordinate2D, Int, Double)] {
            let cellDeg = cellMeters / 111_000.0
            var cells: [SIMD2<Int>: [(CLLocationCoordinate2D, Double)]] = [:]
            for event in events {
                let key = SIMD2<Int>(
                    Int(floor(event.coordinate.latitude  / cellDeg)),
                    Int(floor(event.coordinate.longitude / cellDeg))
                )
                let g = Double(event.formatted.components(separatedBy: " ").first ?? "0") ?? 0
                cells[key, default: []].append((event.coordinate, g))
            }
            return cells.values.compactMap { items -> (CLLocationCoordinate2D, Int, Double)? in
                guard !items.isEmpty else { return nil }
                let lat = items.map(\.0.latitude).reduce(0,  +) / Double(items.count)
                let lon = items.map(\.0.longitude).reduce(0, +) / Double(items.count)
                let maxG = items.map(\.1).max() ?? 0.4
                return (CLLocationCoordinate2D(latitude: lat, longitude: lon), items.count, maxG)
            }
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

        // Red → orange (⅓) → yellow (⅔) → green (max speed)
        private func color(forSpeedMps speedMps: Double, maxMps: Double) -> UIColor {
            let t = CGFloat(min(1.0, speedMps / maxMps))
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
