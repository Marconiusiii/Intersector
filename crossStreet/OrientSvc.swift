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
	func intersections(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) async throws -> [IntersectionCandidate]
	func mapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) async throws -> MapDataSet
}

protocol NeighborhoodProviding {
	func neighborhoods(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance) async throws -> [NeighborhoodCandidate]
}

struct OrientSvc {
	var locationProvider: LocationProviding
	var mapDataClient: MapDataFetching
	var neighborhoodProvider: NeighborhoodProviding
	var finder = IntersectionFinder()
	var neighborhoodResolver = NeighborhoodResolver()

	static let shared = OrientSvc(
		locationProvider: LocationProvider(),
		mapDataClient: MapDataClient(),
		neighborhoodProvider: NeighborhoodProvider()
	)

	func report(
		_ kind: ReportKind,
		rank: Int = 1,
		prefs: AppPrefs = AppPrefs()
	) async throws -> OrientReport {
		let context = try await locationProvider.currentContext()
		let mapData = try await mapData(
			for: kind,
			from: context,
			minimumCandidateCount: rank,
			prefs: prefs
		)
		return try await makeReport(
			kind,
			rank: rank,
			context: context,
			mapData: mapData,
			prefs: prefs
		)
	}

	func spokenText(
		_ kind: ReportKind,
		prefs: AppPrefs = AppPrefs()
	) async throws -> String {
		guard prefs.spokenIntersectionCount != .one else {
			return try await report(kind, prefs: prefs).text(with: prefs)
		}

		let context = try await locationProvider.currentContext()
		let mapData = try await mapDataForStreetPosition(from: context, prefs: prefs)
		if let position = mapData.streetPosition(
			from: context,
			count: prefs.spokenIntersectionCount
		) {
			return position.text(with: prefs)
		}

		let fallback = try await makeReport(
			kind,
			rank: 1,
			context: context,
			mapData: mapData,
			prefs: prefs
		)
		return fallback.text(with: prefs)
	}

	private func makeReport(
		_ kind: ReportKind,
		rank: Int,
		context: DeviceContext,
		mapData: MapDataSet,
		prefs: AppPrefs
	) async throws -> OrientReport {

		let match = if kind == .nearest {
			finder.nearest(
				rank: rank,
				from: context.coordinate,
				in: mapData.intersections
			)
		} else {
			finder.bestMatch(for: kind, from: context, in: mapData.intersections)
		}

		guard let match else {
			throw OrientError.noIntersections
		}

		let distance = Geo.distanceMeters(from: context.coordinate, to: match.coordinate)
		let bearing = Geo.bearingDegrees(from: context.coordinate, to: match.coordinate)
		let relDegrees = relativeDegrees(
			bearing: bearing,
			heading: context.headingDegrees
		)
		let relDir = relativeDirection(
			bearing: bearing,
			heading: context.headingDegrees,
			kind: kind
		)
		let neighborhoodContext = await neighborhoodContext(
			for: prefs.areaMode,
			from: context
		)
		let currentStreet = mapData.nearestRoadName(
			to: context.coordinate,
			matching: match.roadNames
		)
		let crossStreet: String? = currentStreet.flatMap { roadName in
			guard !match.id.hasPrefix("crossing-") else {
				return nil
			}
			let otherNames = match.names.filter { $0 != roadName }
			return otherNames.isEmpty ? nil : otherNames.joined(separator: " and ")
		}

		return OrientReport(
			kind: kind,
			cross: match.title,
			dist: Geo.spokenDistance(distance, unit: prefs.measurementUnit),
			relDir: relDir,
			relDegrees: relDegrees,
			street: currentStreet,
			crossStreet: crossStreet,
			head: Geo.compassDirection(bearing),
			area: neighborhoodContext.area,
			toward: neighborhoodContext.toward,
			conf: confidence(for: kind, heading: context.headingDegrees)
		)
	}

	private func mapDataForStreetPosition(
		from context: DeviceContext,
		prefs: AppPrefs
	) async throws -> MapDataSet {
		let radii: [CLLocationDistance] = [225, 375, 750, 1_200]
		var latestData = MapDataSet(intersections: [], roads: [])

		for radius in radii {
			latestData = try await mapDataClient.mapData(
				near: context.coordinate,
				radiusMeters: radius,
				options: prefs.mapDetails
			)
			if let position = latestData.streetPosition(
				from: context,
				count: prefs.spokenIntersectionCount
			) {
				let needsFollowing = prefs.spokenIntersectionCount == .three &&
					context.dependableTravelDirection != nil
				if !needsFollowing || position.following != nil {
					return latestData
				}
			}
		}

		return latestData
	}

	private func mapData(
		for kind: ReportKind,
		from context: DeviceContext,
		minimumCandidateCount: Int,
		prefs: AppPrefs
	) async throws -> MapDataSet {
		let radii: [CLLocationDistance] = [225, 375, 750, 1_200]
		var latestData = MapDataSet(intersections: [], roads: [])

		for radius in radii {
			latestData = try await mapDataClient.mapData(
				near: context.coordinate,
				radiusMeters: radius,
				options: prefs.mapDetails
			)

			if hasEnoughCandidates(
				for: kind,
				from: context,
				minimumCandidateCount: minimumCandidateCount,
				intersections: latestData.intersections
			) {
				return latestData
			}
		}

		return latestData
	}

	private func hasEnoughCandidates(
		for kind: ReportKind,
		from context: DeviceContext,
		minimumCandidateCount: Int,
		intersections: [IntersectionCandidate]
	) -> Bool {
		if kind == .nearest {
			return finder.rankedNearest(
				from: context.coordinate,
				in: intersections
			).count >= minimumCandidateCount
		}
		return !shouldFetchFallback(for: kind, from: context, intersections: intersections)
	}

	private func neighborhoodContext(
		for mode: AreaMode,
		from context: DeviceContext
	) async -> NeighborhoodContext {
		guard mode != .off else {
			return NeighborhoodContext(area: nil, toward: nil)
		}

		do {
			let neighborhoods = try await neighborhoodProvider.neighborhoods(
				near: context.coordinate,
				radiusMeters: 1_500
			)
			return neighborhoodResolver.context(
				from: neighborhoods,
				origin: context.coordinate,
				heading: context.headingDegrees,
				mode: mode
			)
		} catch {
			return NeighborhoodContext(area: nil, toward: nil)
		}
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
		let degrees = Geo.normalizedDegrees(bearing - heading)

		switch degrees {
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

	private func relativeDegrees(
		bearing: CLLocationDirection,
		heading: CLLocationDirection?
	) -> CLLocationDirection? {
		guard let heading else {
			return nil
		}
		return Geo.normalizedDegrees(bearing - heading)
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

	static func spokenDistance(_ meters: CLLocationDistance, unit: MeasurementUnit = .feet) -> String {
		switch unit {
		case .feet:
			spokenFeetDistance(meters)
		case .meters:
			spokenMeterDistance(meters)
		}
	}

	private static func spokenFeetDistance(_ meters: CLLocationDistance) -> String {
		let feet = meters * 3.28084
		if feet < 500 {
			let rounded = (feet / 10).rounded() * 10
			return "\(Int(rounded)) feet"
		}
		let miles = feet / 5280
		return String(format: "%.1f miles", miles)
	}

	private static func spokenMeterDistance(_ meters: CLLocationDistance) -> String {
		if meters < 1_000 {
			let rounded = (meters / 5).rounded() * 5
			return "\(Int(rounded)) meters"
		}
		let kilometers = meters / 1_000
		return String(format: "%.1f kilometers", kilometers)
	}
}
