//
//  RouteGapFill.swift
//  DriverStats
//

import CoreLocation
import Foundation
import MapKit
import SwiftData

// Two consecutive GPS points more than this distance apart trigger a road-fill request.
private let gapFillThresholdM: Double = 1000

// Requests a road-following automobile route between two coordinates via MapKit Directions.
// Returns the polyline coordinates, or nil if MapKit can't find a route or is throttled.
func roadRoute(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) async -> [CLLocationCoordinate2D]? {
    let request = MKDirections.Request()
    request.source      = MKMapItem(placemark: MKPlacemark(coordinate: start))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
    request.transportType = .automobile
    do {
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { return nil }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: route.polyline.pointCount
        )
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: route.polyline.pointCount))
        return coords.filter { CLLocationCoordinate2DIsValid($0) }
    } catch {
        // Includes MKError.loadingThrottled — caller delays before next request.
        return nil
    }
}

// Scans consecutive pairs in the session's route arrays. Where two adjacent points are
// more than gapFillThresholdM apart, a road route is requested and its intermediate
// coordinates are spliced in. Speed and altitude are linearly interpolated across the gap.
// Saves the context if any gaps were filled.
@MainActor
func fillRouteGaps(session: DriveSession, context: ModelContext) async {
    let lats   = session.routeLatitudes
    let lons   = session.routeLongitudes
    let speeds = session.routeSpeeds
    let alts   = session.routeAltitudes
    guard lats.count >= 2 else { return }

    var newLats: [Double]   = []
    var newLons: [Double]   = []
    var newSpeeds: [Double] = []
    var newAlts: [Double]   = []
    var anyFilled = false

    for i in 0..<lats.count {
        newLats.append(lats[i])
        newLons.append(lons[i])
        newSpeeds.append(i < speeds.count ? speeds[i] : 0)
        newAlts.append(i < alts.count ? alts[i] : 0)

        guard i + 1 < lats.count else { continue }

        let a = CLLocation(latitude: lats[i],     longitude: lons[i])
        let b = CLLocation(latitude: lats[i + 1], longitude: lons[i + 1])
        guard a.distance(from: b) > gapFillThresholdM else { continue }

        let fromCoord = CLLocationCoordinate2D(latitude: lats[i],     longitude: lons[i])
        let toCoord   = CLLocationCoordinate2D(latitude: lats[i + 1], longitude: lons[i + 1])

        // Delay between successive MKDirections calls to avoid throttling.
        if anyFilled { try? await Task.sleep(for: .milliseconds(600)) }

        guard let fill = await roadRoute(from: fromCoord, to: toCoord) else { continue }

        let startSpeed = i < speeds.count ? speeds[i]         : 0
        let endSpeed   = i + 1 < speeds.count ? speeds[i + 1] : 0
        let startAlt   = i < alts.count ? alts[i]             : 0
        let endAlt     = i + 1 < alts.count ? alts[i + 1]     : 0
        let n = fill.count

        // Insert intermediate coordinates (skip fill[0] and fill[n-1] which duplicate
        // the existing points at index i and i+1).
        for (j, coord) in fill.enumerated() where j > 0 && j < n - 1 {
            let t = Double(j) / Double(max(n - 1, 1))
            newLats.append(coord.latitude)
            newLons.append(coord.longitude)
            newSpeeds.append(startSpeed + t * (endSpeed - startSpeed))
            newAlts.append(startAlt + t * (endAlt - startAlt))
        }
        anyFilled = true
    }

    guard anyFilled else { return }
    session.routeLatitudes  = newLats
    session.routeLongitudes = newLons
    session.routeSpeeds     = newSpeeds
    session.routeAltitudes  = newAlts
    try? context.save()
}
