//
//  OrientSvc.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Foundation

enum OrientError: LocalizedError {
	case noIntersections
	case headingUnavailable
	case locationUnavailable

	var errorDescription: String? {
		switch self {
		case .noIntersections:
			"No nearby mapped intersections were found."
		case .headingUnavailable:
			"Direction is not available yet."
		case .locationUnavailable:
			"Location is not available yet. Try again."
		}
	}
}

protocol LocationProviding {
	func currentContext() async throws -> DeviceContext
}

protocol MapDataFetching {
	func intersections(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance) async throws -> [IntersectionCandidate]
	func mapData(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance) async throws -> MapDataSet
}

struct OrientSvc {
	var locationProvider: LocationProviding
	var mapDataClient: MapDataFetching
	var finder = IntersectionFinder()

	static let shared = OrientSvc(
		locationProvider: LocationProvider(),
		mapDataClient: MapDataClient()
	)

	func report(_ kind: ReportKind, prefs: AppPrefs = AppPrefs()) async throws -> OrientReport {
		let context = try await locationProvider.currentContext()
		let intersections = try await intersections(for: kind, from: context)

		guard let match = finder.bestMatch(
			for: kind,
			from: context,
			in: intersections
		) else {
			throw OrientError.noIntersections
		}

		let distance = Geo.distanceMeters(from: context.coordinate, to: match.coordinate)
		let bearing = Geo.bearingDegrees(from: context.coordinate, to: match.coordinate)
		let relDir = relativeDirection(
			bearing: bearing,
			heading: context.headingDegrees,
			kind: kind
		)

		return OrientReport(
			kind: kind,
			cross: match.title,
			dist: Geo.spokenDistance(distance),
			relDir: relDir,
			street: match.names.first,
			head: Geo.compassDirection(bearing),
			area: nil,
			toward: nil,
			conf: confidence(for: kind, heading: context.headingDegrees)
		)
	}

	private func intersections(for kind: ReportKind, from context: DeviceContext) async throws -> [IntersectionCandidate] {
		let fastRadius: CLLocationDistance = 225
		let fallbackRadius: CLLocationDistance = 375
		let intersections = try await mapDataClient.intersections(
			near: context.coordinate,
			radiusMeters: fastRadius
		)

		if shouldFetchFallback(for: kind, from: context, intersections: intersections) {
			return try await mapDataClient.intersections(
				near: context.coordinate,
				radiusMeters: fallbackRadius
			)
		}

		return intersections
	}

	private func shouldFetchFallback(
		for kind: ReportKind,
		from context: DeviceContext,
		intersections: [IntersectionCandidate]
	) -> Bool {
		guard !intersections.isEmpty else {
			return true
		}

		guard kind == .upcoming, let heading = context.headingDegrees else {
			return false
		}

		return !intersections.contains { candidate in
			let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
			return finder.angleDelta(from: heading, to: bearing) <= 60
		}
	}

	private func relativeDirection(
		bearing: CLLocationDirection,
		heading: CLLocationDirection?,
		kind: ReportKind
	) -> String? {
		guard let heading else {
			return kind == .nearest ? Geo.compassDirection(bearing) : nil
		}
		let delta = Geo.normalizedDegrees(bearing - heading)

		switch delta {
		case 337.5...360, 0..<22.5:
			return "ahead"
		case 22.5..<67.5:
			return "ahead and right"
		case 67.5..<112.5:
			return "right"
		case 112.5..<157.5:
			return "behind and right"
		case 157.5..<202.5:
			return "behind"
		case 202.5..<247.5:
			return "behind and left"
		case 247.5..<292.5:
			return "left"
		default:
			return "ahead and left"
		}
	}

	private func confidence(for kind: ReportKind, heading: CLLocationDirection?) -> ConfLev {
		switch (kind, heading) {
		case (.nearest, _):
			.high
		case (_, .some):
			.medium
		case (_, .none):
			.low
		}
	}
}

enum Geo {
	static func distanceMeters(
		from start: CLLocationCoordinate2D,
		to end: CLLocationCoordinate2D
	) -> CLLocationDistance {
		CLLocation(latitude: start.latitude, longitude: start.longitude)
			.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
	}

	static func bearingDegrees(
		from start: CLLocationCoordinate2D,
		to end: CLLocationCoordinate2D
	) -> CLLocationDirection {
		let lat1 = start.latitude * .pi / 180
		let lat2 = end.latitude * .pi / 180
		let lonDelta = (end.longitude - start.longitude) * .pi / 180
		let y = sin(lonDelta) * cos(lat2)
		let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lonDelta)
		return normalizedDegrees(atan2(y, x) * 180 / .pi)
	}

	static func normalizedDegrees(_ degrees: CLLocationDirection) -> CLLocationDirection {
		let value = degrees.truncatingRemainder(dividingBy: 360)
		return value >= 0 ? value : value + 360
	}

	static func compassDirection(_ degrees: CLLocationDirection) -> String {
		let names = [
			"north", "northeast", "east", "southeast",
			"south", "southwest", "west", "northwest"
		]
		let index = Int((normalizedDegrees(degrees) + 22.5) / 45) % names.count
		return names[index]
	}

	static func spokenDistance(_ meters: CLLocationDistance) -> String {
		let feet = meters * 3.28084
		if feet < 500 {
			let rounded = (feet / 10).rounded() * 10
			return "\(Int(rounded)) feet"
		}
		let miles = feet / 5280
		return String(format: "%.1f miles", miles)
	}
}
