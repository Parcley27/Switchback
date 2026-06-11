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

// MARK: - Map view

struct RouteMapView: UIViewRepresentable {
    let track: [RoutePoint]
    var peakEvents: [PeakEvent] = []
    var thumbnailMode: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        guard track.count >= 2 else { return }

        let coordinates = track.map(\.coordinate)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        context.coordinator.speedsAtPoints = track.map(\.speedMps)
        context.coordinator.thumbnailMode = thumbnailMode
        map.addOverlay(polyline, level: .aboveRoads)

        for event in peakEvents {
            map.addAnnotation(PeakAnnotation(event))
        }

        let padding: UIEdgeInsets = thumbnailMode
            ? UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            : UIEdgeInsets(top: 60, left: 40, bottom: 40, right: 40)
        map.setVisibleMapRect(polyline.boundingMapRect, edgePadding: padding, animated: false)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var speedsAtPoints: [Double] = []
        var thumbnailMode: Bool = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }

            if thumbnailMode {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 2
                renderer.lineCap = .round
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
            }
            return view
        }

        // Red → orange (⅓) → yellow (⅔) → green (max speed)
        private func color(forSpeedMps speedMps: Double, maxMps: Double) -> UIColor {
            let t = CGFloat(min(1.0, speedMps / maxMps))
            // Map 3 equal segments: red→orange, orange→yellow, yellow→green
            let hue: CGFloat
            if t < 1/3 {
                hue = t * 3 * (30.0 / 360.0)           // 0° → 30° (red → orange)
            } else if t < 2/3 {
                hue = 30.0/360.0 + (t - 1/3) * 3 * (30.0 / 360.0)  // 30° → 60° (orange → yellow)
            } else {
                hue = 60.0/360.0 + (t - 2/3) * 3 * (60.0 / 360.0)  // 60° → 120° (yellow → green)
            }
            return UIColor(hue: hue, saturation: 1, brightness: 0.9, alpha: 1)
        }
    }
}
