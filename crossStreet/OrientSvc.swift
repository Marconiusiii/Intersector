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
	func currentContext(requiresFreshHeading: Bool) async throws -> DeviceContext
}

extension LocationProviding {
	func currentContext(requiresFreshHeading: Bool) async throws -> DeviceContext {
		try await currentContext()
	}
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
	private var upcomingCache = UpcomingReportCache()

	init(
		locationProvider: LocationProviding,
		mapDataClient: MapDataFetching,
		neighborhoodProvider: NeighborhoodProviding,
		finder: IntersectionFinder = IntersectionFinder(),
		neighborhoodResolver: NeighborhoodResolver = NeighborhoodResolver()
	) {
		self.locationProvider = locationProvider
		self.mapDataClient = mapDataClient
		self.neighborhoodProvider = neighborhoodProvider
		self.finder = finder
		self.neighborhoodResolver = neighborhoodResolver
	}

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
		if
			kind == .upcoming,
			rank > 1,
			let cachedReport = await upcomingCache.report(rank: rank, prefs: prefs)
		{
			return cachedReport
		}
		let context = try await locationProvider.currentContext(requiresFreshHeading: kind == .upcoming || kind == .scan)
		let mapData = try await mapData(
			for: kind,
			from: context,
			minimumCandidateCount: rank,
			prefs: prefs
		)
		if kind == .upcoming {
			let reports = await upcomingReports(
				from: context,
				mapData: mapData,
				prefs: prefs,
				maxCount: 3
			)
			await upcomingCache.store(reports: reports, prefs: prefs)
			guard reports.indices.contains(rank - 1) else {
				throw OrientError.noIntersections
			}
			return reports[rank - 1]
		}
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

		let context = try await locationProvider.currentContext(requiresFreshHeading: kind == .upcoming || kind == .scan)
		let requestedCount = prefs.spokenIntersectionCount.rawValue
		let minimumCandidateCount = kind == .upcoming && context.headingDegrees == nil
			? 1
			: requestedCount
		let mapData = try await mapData(
			for: kind,
			from: context,
			minimumCandidateCount: minimumCandidateCount,
			prefs: prefs
		)
		let ranked: [IntersectionCandidate]
		switch kind {
		case .nearest:
			ranked = finder.rankedNearest(from: context.coordinate, in: mapData.intersections)
		case .upcoming:
			if context.headingDegrees == nil {
				ranked = finder.rankedNearest(from: context.coordinate, in: mapData.intersections)
			} else {
				ranked = finder.rankedUpcoming(from: context, in: mapData.intersections)
			}
		case .scan:
			ranked = finder.scanMatch(from: context, in: mapData.intersections).map { [$0.candidate] } ?? []
		}
		let resultCount = kind == .upcoming && context.headingDegrees == nil ? 1 : requestedCount
		let neighborhoodContext = await neighborhoodContext(for: prefs.areaMode, from: context)
		var reports: [OrientReport] = []
		for match in ranked {
			let report = makeReport(
				kind,
				match: match,
				context: context,
				mapData: mapData,
				prefs: prefs,
				neighborhoodContext: neighborhoodContext
			)
			if !reports.containsSpokenIntersection(matching: report) {
				reports.append(report)
			}
			if reports.count == resultCount {
				break
			}
		}
		guard !reports.isEmpty else {
			throw OrientError.noIntersections
		}
		if kind == .upcoming {
			await upcomingCache.store(reports: reports, prefs: prefs)
		}
		return IntersectionReportList(reports: reports).text(with: prefs)
	}

	private func upcomingReports(
		from context: DeviceContext,
		mapData: MapDataSet,
		prefs: AppPrefs,
		maxCount: Int
	) async -> [OrientReport] {
		let ranked: [IntersectionCandidate]
		if context.headingDegrees == nil {
			ranked = finder.rankedNearest(from: context.coordinate, in: mapData.intersections)
		} else {
			ranked = finder.rankedUpcoming(from: context, in: mapData.intersections)
		}
		let neighborhoodContext = await neighborhoodContext(for: prefs.areaMode, from: context)
		var reports: [OrientReport] = []
		for match in ranked {
			let report = makeReport(
				.upcoming,
				match: match,
				context: context,
				mapData: mapData,
				prefs: prefs,
				neighborhoodContext: neighborhoodContext
			)
			if !reports.containsSpokenIntersection(matching: report) {
				reports.append(report)
			}
			if reports.count == maxCount {
				break
			}
		}
		return reports
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
		} else if kind == .scan {
			finder.scanMatch(from: context, in: mapData.intersections)?.candidate
		} else if rank > 1 {
			finder.upcoming(
				rank: rank,
				from: context,
				in: mapData.intersections
			)
		} else {
			finder.bestMatch(for: kind, from: context, in: mapData.intersections)
		}
		guard let match else {
			throw OrientError.noIntersections
		}
		let neighborhoodContext = await neighborhoodContext(for: prefs.areaMode, from: context)
		return makeReport(
			kind,
			match: match,
			context: context,
			mapData: mapData,
			prefs: prefs,
			neighborhoodContext: neighborhoodContext
		)
	}

	private func makeReport(
		_ kind: ReportKind,
		match: IntersectionCandidate,
		context: DeviceContext,
		mapData: MapDataSet,
		prefs: AppPrefs,
		neighborhoodContext: NeighborhoodContext
	) -> OrientReport {
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
		let currentStreet = mapData.nearestRoadName(
			to: context.coordinate,
			matching: match.roadNames
		)
		let crossStreet: String? = currentStreet.flatMap { roadName in
			let otherNames = mapData.crossStreetNames(
				for: match,
				on: roadName,
				heading: context.dependableTravelDirection
			)
			return otherNames.isEmpty ? nil : otherNames.joined(separator: " and ")
		}
		let cross = currentStreet.flatMap { roadName in
			crossStreet.map { "\(roadName) and \($0)" }
		} ?? match.title

		return OrientReport(
			kind: kind,
			cross: cross,
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
		guard context.headingDegrees != nil else {
			return !intersections.isEmpty
		}
		if kind == .scan {
			return finder.scanMatch(from: context, in: intersections) != nil
		}
		return finder.rankedUpcoming(from: context, in: intersections).count >= minimumCandidateCount
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

private extension Array where Element == OrientReport {
	func containsSpokenIntersection(matching report: OrientReport) -> Bool {
		contains { existing in
			if
				let existingStreet = existing.street,
				let existingCrossStreet = existing.crossStreet,
				let reportStreet = report.street,
				let reportCrossStreet = report.crossStreet
			{
				return existingStreet == reportStreet && existingCrossStreet == reportCrossStreet
			}
			return existing.cross == report.cross
		}
	}
}

actor UpcomingReportCache {
	private var entry: Entry?
	private let timeToLive: TimeInterval = 60

	func store(reports: [OrientReport], prefs: AppPrefs, now: Date = .now) {
		guard !reports.isEmpty else {
			return
		}
		entry = Entry(
			reports: reports,
			prefsKey: UpcomingPrefsKey(prefs),
			storedAt: now
		)
	}

	func report(rank: Int, prefs: AppPrefs, now: Date = .now) -> OrientReport? {
		guard
			rank > 1,
			let entry,
			now.timeIntervalSince(entry.storedAt) <= timeToLive,
			entry.prefsKey == UpcomingPrefsKey(prefs),
			entry.reports.indices.contains(rank - 1)
		else {
			return nil
		}
		return entry.reports[rank - 1]
	}

	private struct Entry {
		var reports: [OrientReport]
		var prefsKey: UpcomingPrefsKey
		var storedAt: Date
	}
}

private struct UpcomingPrefsKey: Equatable {
	var areaMode: AreaMode
	var measurementUnit: MeasurementUnit
	var directionStyle: DirectionStyle
	var intersectionWording: IntersectionWording
	var announcementOptions: AnnouncementOptions
	var mapDetails: MapDetailOptions
	var manhattanSnobMode: Bool

	init(_ prefs: AppPrefs) {
		areaMode = prefs.areaMode
		measurementUnit = prefs.measurementUnit
		directionStyle = prefs.directionStyle
		intersectionWording = prefs.intersectionWording
		announcementOptions = prefs.announcementOptions
		mapDetails = prefs.mapDetails
		manhattanSnobMode = prefs.manhattanSnobMode
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

	static func localizedDirection(_ degrees: CLLocationDirection, prefs: AppPrefs) -> String {
		let direction = compassDirection(degrees)
		guard prefs.manhattanSnobMode else {
			return direction
		}
		return manhattanDirection(for: direction)
	}

	static func manhattanDirection(for direction: String) -> String {
		switch direction {
		case "north", "northeast":
			"Uptown"
		case "east", "southeast":
			"East Side"
		case "south", "southwest":
			"Downtown"
		case "west", "northwest":
			"West Side"
		default:
			direction
		}
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
