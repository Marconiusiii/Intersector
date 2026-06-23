//
//  IntersectorTests.swift
//  IntersectorTests
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Testing
@testable import Intersector

struct IntersectorTests {
	@Test func reportTextCanHideArea() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .off
		let report = OrientReport(
			kind: .nearest,
			cross: "Oak Street and Pine Street",
			dist: "80 feet",
			relDir: "ahead",
			relDegrees: 0,
			street: "Oak Street",
			head: "north",
			area: "Downtown",
			toward: nil,
			conf: .high
		)

		let text = report.text(with: prefs)

		#expect(text.contains("Nearest:"))
		#expect(text.contains("Oak Street and Pine Street"))
		#expect(text.contains("80 feet ahead"))
		#expect(!text.contains("On Oak Street"))
		#expect(!text.contains("appears"))
		#expect(!text.contains("Downtown"))
	}

	@Test func reportTextUsesClockFaceDirection() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .toward
		prefs.directionStyle = .clockFace
		let report = OrientReport(
			kind: .upcoming,
			cross: "Mission Street and 6th Street",
			dist: "140 feet",
			relDir: "ahead and right",
			relDegrees: 45,
			street: "Mission Street",
			head: "northeast",
			area: nil,
			toward: "Civic Center",
			conf: .high
		)

		let text = report.text(with: prefs)

		#expect(text == "Upcoming: Mission Street and 6th Street, about 140 feet at 2 o'clock toward Civic Center.")
	}

	@Test func streetContextNamesCurrentStreetBeforeCrossStreet() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .off
		prefs.intersectionWording = .streetContext
		let report = OrientReport(
			kind: .upcoming,
			cross: "E 20th Avenue and Main Street",
			dist: "140 feet",
			relDir: "ahead",
			relDegrees: 0,
			street: "E 20th Avenue",
			crossStreet: "Main Street",
			head: "north",
			area: nil,
			toward: nil,
			conf: .high
		)

		#expect(report.text(with: prefs) == "Upcoming: On E 20th Avenue, Main Street is about 140 feet ahead.")
	}

	@Test func streetContextFallsBackToDirectWordingWithoutCurrentStreet() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .off
		prefs.intersectionWording = .streetContext
		let report = OrientReport(
			kind: .nearest,
			cross: "E 20th Avenue and Main Street",
			dist: "80 feet",
			relDir: "left",
			relDegrees: 270,
			street: nil,
			head: "west",
			area: nil,
			toward: nil,
			conf: .high
		)

		#expect(report.text(with: prefs) == "Nearest: E 20th Avenue and Main Street, about 80 feet left.")
	}

	@Test func reportTextOmitsDynamicConfidenceWording() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .off
		let report = OrientReport(
			kind: .upcoming,
			cross: "Oak Street and Pine Street",
			dist: "100 feet",
			relDir: "ahead",
			relDegrees: 0,
			street: "Oak Street",
			head: "north",
			area: nil,
			toward: nil,
			conf: .medium
		)

		let text = report.text(with: prefs)

		#expect(text == "Upcoming: Oak Street and Pine Street, about 100 feet ahead.")
		#expect(!text.localizedCaseInsensitiveContains("estimate"))
		#expect(!text.localizedCaseInsensitiveContains("uncertain"))
	}

	@Test func briefVerbosityOmitsNeighborhoodContext() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .toward
		prefs.detail = .brief
		let report = OrientReport(
			kind: .upcoming,
			cross: "Mission Street and 6th Street",
			dist: "140 feet",
			relDir: "ahead and right",
			relDegrees: 45,
			street: "Mission Street",
			head: "northeast",
			area: "SoMa",
			toward: "Civic Center",
			conf: .high
		)

		let text = report.text(with: prefs)

		#expect(text == "Upcoming: Mission Street and 6th Street, about 140 feet ahead and right.")
	}

	@Test func standardVerbosityIncludesNeighborhoodContext() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .toward
		prefs.detail = .standard
		let report = OrientReport(
			kind: .upcoming,
			cross: "Mission Street and 6th Street",
			dist: "140 feet",
			relDir: "ahead and right",
			relDegrees: 45,
			street: "Mission Street",
			head: "northeast",
			area: "SoMa",
			toward: "Civic Center",
			conf: .high
		)

		let text = report.text(with: prefs)

		#expect(text == "Upcoming: Mission Street and 6th Street, about 140 feet ahead and right toward Civic Center.")
	}

	@Test func distanceTextCanUseMeters() async throws {
		#expect(Geo.spokenDistance(42, unit: .meters) == "40 meters")
		#expect(Geo.spokenDistance(1_200, unit: .meters) == "1.2 kilometers")
	}

	@Test func pointedReportOmitsRedundantDirectionText() async throws {
		let report = OrientReport(
			kind: .scan,
			cross: "Valencia Street and 16th Street",
			dist: "220 feet",
			relDir: nil,
			relDegrees: nil,
			street: "Valencia Street",
			head: "north",
			area: nil,
			toward: nil,
			conf: .high
		)

		let text = report.text(with: AppPrefs())

		#expect(text == "Pointed: Valencia Street and 16th Street, about 220 feet.")
		#expect(!text.localizedCaseInsensitiveContains("where the phone is pointing"))
	}

	@Test func currentStreetMatchingIgnoresUnrelatedCloserRoad() async throws {
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
		let mapData = MapDataSet(
			intersections: [],
			roads: [
				MapRoad(
					id: "oak",
					name: "Oak Street",
					nodeIDs: [1, 2],
					coordinates: [
						CLLocationCoordinate2D(latitude: 37.0, longitude: -122.001),
						CLLocationCoordinate2D(latitude: 37.0, longitude: -121.999)
					]
				),
				MapRoad(
					id: "pine",
					name: "Pine Street",
					nodeIDs: [3, 4],
					coordinates: [
						CLLocationCoordinate2D(latitude: 37.0005, longitude: -122.0005),
						CLLocationCoordinate2D(latitude: 37.0005, longitude: -121.9995)
					]
				),
				MapRoad(
					id: "service",
					name: "Service Road",
					nodeIDs: [5],
					coordinates: [origin]
				)
			]
		)

		let street = mapData.nearestRoadName(
			to: origin,
			matching: ["Oak Street", "Pine Street"]
		)

		#expect(street == "Oak Street")
	}

	@Test func roadDistanceUsesFullSegmentBetweenNodes() async throws {
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
		let road = MapRoad(
			id: "oak",
			name: "Oak Street",
			nodeIDs: [1, 2],
			coordinates: [
				CLLocationCoordinate2D(latitude: 37.0, longitude: -122.001),
				CLLocationCoordinate2D(latitude: 37.0, longitude: -121.999)
			]
		)

		#expect(road.minimumDistance(to: origin) < 1)
	}

	@Test func upcomingPrefersCandidateAhead() async throws {
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
		let context = DeviceContext(coordinate: origin, headingDegrees: 0)
		let candidates = [
			IntersectionCandidate(
				id: "west",
				names: ["First Street", "West Street"],
				coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.001)
			),
			IntersectionCandidate(
				id: "north",
				names: ["First Street", "North Street"],
				coordinate: CLLocationCoordinate2D(latitude: 37.001, longitude: -122.0)
			)
		]

		let match = IntersectionFinder().bestMatch(
			for: .upcoming,
			from: context,
			in: candidates
		)

		#expect(match?.id == "north")
	}

	@Test func pointScanFiltersToCurrentStreetIntersections() async throws {
		let response = OverpassResponse(
			elements: [
				OverpassElement(type: "node", id: 1, lat: 37.0, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 2, lat: 37.001, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 3, lat: 37.002, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 4, lat: 37.001, lon: -122.001, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 5, lat: 37.01, lon: -122.01, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 6, lat: 37.011, lon: -122.01, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 7, lat: 37.01, lon: -122.011, nodes: nil, tags: nil),
				OverpassElement(type: "way", id: 10, lat: nil, lon: nil, nodes: [1, 2, 3], tags: ["highway": "residential", "name": "Oak Street"]),
				OverpassElement(type: "way", id: 11, lat: nil, lon: nil, nodes: [4, 2], tags: ["highway": "residential", "name": "Pine Street"]),
				OverpassElement(type: "way", id: 12, lat: nil, lon: nil, nodes: [5, 6], tags: ["highway": "residential", "name": "Distant Street"]),
				OverpassElement(type: "way", id: 13, lat: nil, lon: nil, nodes: [7, 5], tags: ["highway": "residential", "name": "Far Avenue"])
			]
		)
		let data = IntersectionBuilder().mapData(from: response)
		let origin = CLLocationCoordinate2D(latitude: 37.0002, longitude: -122.0)

		let currentStreetIntersections = data.currentStreetIntersections(from: origin)

		#expect(currentStreetIntersections.map(\.title) == ["Oak Street and Pine Street"])
	}

	@Test func mapDataCacheReusesNearbyResults() async throws {
		let cache = MapDataCache()
		let counter = FetchCounter()
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
		let nearby = CLLocationCoordinate2D(latitude: 37.0002, longitude: -122.0)

		let first = try await cache.data(near: origin, radiusMeters: 450) {
			await counter.nextDataSet()
		}
		let second = try await cache.data(near: nearby, radiusMeters: 450) {
			await counter.nextDataSet()
		}

		#expect(first.intersections.first?.id == "fetch-1")
		#expect(second.intersections.first?.id == "fetch-1")
		#expect(await counter.count == 1)
	}

	@Test func mapDataCacheFetchesAgainForDistantResults() async throws {
		let cache = MapDataCache()
		let counter = FetchCounter()
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
		let distant = CLLocationCoordinate2D(latitude: 37.002, longitude: -122.0)

		let first = try await cache.data(near: origin, radiusMeters: 450) {
			await counter.nextDataSet()
		}
		let second = try await cache.data(near: distant, radiusMeters: 450) {
			await counter.nextDataSet()
		}

		#expect(first.intersections.first?.id == "fetch-1")
		#expect(second.intersections.first?.id == "fetch-2")
		#expect(await counter.count == 2)
	}

	@Test func mapDataCacheKeepsSeveralRecentAreas() async throws {
		let cache = MapDataCache()
		let counter = FetchCounter()
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
		let distant = CLLocationCoordinate2D(latitude: 37.002, longitude: -122.0)

		let first = try await cache.data(near: origin, radiusMeters: 225) {
			await counter.nextDataSet()
		}
		let second = try await cache.data(near: distant, radiusMeters: 225) {
			await counter.nextDataSet()
		}
		let reusedFirst = try await cache.data(near: origin, radiusMeters: 225) {
			await counter.nextDataSet()
		}

		#expect(first.intersections.first?.id == "fetch-1")
		#expect(second.intersections.first?.id == "fetch-2")
		#expect(reusedFirst.intersections.first?.id == "fetch-1")
		#expect(await counter.count == 2)
	}

	@Test func mapDataCacheSeparatesMapDetailOptions() async throws {
		let cache = MapDataCache()
		let counter = FetchCounter()
		let origin = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)

		let first = try await cache.data(near: origin, radiusMeters: 450, options: MapDetailOptions()) {
			await counter.nextDataSet()
		}
		let second = try await cache.data(
			near: origin,
			radiusMeters: 450,
			options: MapDetailOptions(includeCrossings: true)
		) {
			await counter.nextDataSet()
		}

		#expect(first.intersections.first?.id == "fetch-1")
		#expect(second.intersections.first?.id == "fetch-2")
		#expect(await counter.count == 2)
	}

	@Test func intersectionBuilderIgnoresNonStreetPaths() async throws {
		let response = OverpassResponse(
			elements: [
				OverpassElement(type: "node", id: 1, lat: 37.0, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 2, lat: 37.001, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 3, lat: 37.0, lon: -122.001, nodes: nil, tags: nil),
				OverpassElement(type: "way", id: 10, lat: nil, lon: nil, nodes: [1, 2], tags: ["highway": "residential", "name": "Oak Street"]),
				OverpassElement(type: "way", id: 11, lat: nil, lon: nil, nodes: [3, 1], tags: ["highway": "footway", "name": "Garden Path"])
			]
		)

		let data = IntersectionBuilder().mapData(from: response)

		#expect(data.intersections.isEmpty)
		#expect(data.roads.map(\.name) == ["Oak Street"])
	}

	@Test func intersectionBuilderIncludesWalkingPathsWhenEnabled() async throws {
		let response = OverpassResponse(
			elements: [
				OverpassElement(type: "node", id: 1, lat: 37.0, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 2, lat: 37.001, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 3, lat: 37.0, lon: -122.001, nodes: nil, tags: nil),
				OverpassElement(type: "way", id: 10, lat: nil, lon: nil, nodes: [1, 2], tags: ["highway": "residential", "name": "Oak Street"]),
				OverpassElement(type: "way", id: 11, lat: nil, lon: nil, nodes: [3, 1], tags: ["highway": "footway", "name": "Garden Path"])
			]
		)
		let options = MapDetailOptions(includeWalkingPaths: true)

		let data = IntersectionBuilder().mapData(from: response, options: options)

		#expect(data.intersections.map(\.title) == ["Garden Path and Oak Street"])
		#expect(data.roads.map(\.name) == ["Oak Street", "Garden Path"])
	}

	@Test func intersectionBuilderIgnoresCrossingsByDefault() async throws {
		let response = OverpassResponse(
			elements: [
				OverpassElement(type: "node", id: 1, lat: 37.0, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 2, lat: 37.001, lon: -122.0, nodes: nil, tags: ["highway": "crossing"]),
				OverpassElement(type: "node", id: 3, lat: 37.002, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "way", id: 10, lat: nil, lon: nil, nodes: [1, 2, 3], tags: ["highway": "residential", "name": "Oak Street"])
			]
		)

		let data = IntersectionBuilder().mapData(from: response)

		#expect(data.intersections.isEmpty)
	}

	@Test func intersectionBuilderIncludesCrossingsWhenEnabled() async throws {
		let response = OverpassResponse(
			elements: [
				OverpassElement(type: "node", id: 1, lat: 37.0, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "node", id: 2, lat: 37.001, lon: -122.0, nodes: nil, tags: ["highway": "crossing"]),
				OverpassElement(type: "node", id: 3, lat: 37.002, lon: -122.0, nodes: nil, tags: nil),
				OverpassElement(type: "way", id: 10, lat: nil, lon: nil, nodes: [1, 2, 3], tags: ["highway": "residential", "name": "Oak Street"])
			]
		)
		let options = MapDetailOptions(includeCrossings: true)

		let data = IntersectionBuilder().mapData(from: response, options: options)

		#expect(data.intersections.map(\.title) == ["Crossing on Oak Street"])
	}

	@Test func areaModeOffSkipsNeighborhoodLookup() async throws {
		let neighborhoodProvider = FakeNeighborhoodProvider(candidates: [
			NeighborhoodCandidate(
				id: "mission",
				name: "Mission District",
				coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
				kind: .neighbourhood
			)
		])
		var prefs = AppPrefs()
		prefs.areaMode = .off
		let service = OrientSvc(
			locationProvider: FakeLocationProvider(
				context: DeviceContext(
					coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
					headingDegrees: nil
				)
			),
			mapDataClient: FakeMapDataClient(),
			neighborhoodProvider: neighborhoodProvider
		)

		let report = try await service.report(.nearest, prefs: prefs)

		#expect(report.area == nil)
		#expect(report.toward == nil)
		#expect(await neighborhoodProvider.requestCount == 0)
	}

	@Test func areaModeNearAddsNeighborhoodText() async throws {
		let neighborhoodProvider = FakeNeighborhoodProvider(candidates: [
			NeighborhoodCandidate(
				id: "mission",
				name: "Mission District",
				coordinate: CLLocationCoordinate2D(latitude: 37.0001, longitude: -122.0),
				kind: .neighbourhood
			)
		])
		var prefs = AppPrefs()
		prefs.areaMode = .near
		let service = OrientSvc(
			locationProvider: FakeLocationProvider(
				context: DeviceContext(
					coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
					headingDegrees: nil
				)
			),
			mapDataClient: FakeMapDataClient(),
			neighborhoodProvider: neighborhoodProvider
		)

		let report = try await service.report(.nearest, prefs: prefs)
		let text = report.text(with: prefs)

		#expect(report.area == "Mission District")
		#expect(text.contains("in Mission District"))
		#expect(await neighborhoodProvider.requestCount == 1)
	}

	@Test func areaModeTowardUsesHeadingAwareNeighborhood() async throws {
		let neighborhoodProvider = FakeNeighborhoodProvider(candidates: [
			NeighborhoodCandidate(
				id: "mission",
				name: "Mission District",
				coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.001),
				kind: .neighbourhood
			),
			NeighborhoodCandidate(
				id: "north-beach",
				name: "North Beach",
				coordinate: CLLocationCoordinate2D(latitude: 37.01, longitude: -122.0),
				kind: .neighbourhood
			)
		])
		var prefs = AppPrefs()
		prefs.areaMode = .toward
		let service = OrientSvc(
			locationProvider: FakeLocationProvider(
				context: DeviceContext(
					coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
					headingDegrees: 0
				)
			),
			mapDataClient: FakeMapDataClient(),
			neighborhoodProvider: neighborhoodProvider
		)

		let report = try await service.report(.nearest, prefs: prefs)
		let text = report.text(with: prefs)

		#expect(report.area == "Mission District")
		#expect(report.toward == "North Beach")
		#expect(text.contains("toward North Beach"))
	}

	@Test func neighborhoodFailureDoesNotFailIntersectionReport() async throws {
		var prefs = AppPrefs()
		prefs.areaMode = .near
		let service = OrientSvc(
			locationProvider: FakeLocationProvider(
				context: DeviceContext(
					coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
					headingDegrees: nil
				)
			),
			mapDataClient: FakeMapDataClient(),
			neighborhoodProvider: FailingNeighborhoodProvider()
		)

		let report = try await service.report(.nearest, prefs: prefs)

		#expect(report.cross == "Oak Street and Pine Street")
		#expect(report.area == nil)
		#expect(report.toward == nil)
	}
}

actor FetchCounter {
	private(set) var count = 0

	func nextDataSet() -> MapDataSet {
		count += 1
		let id = "fetch-\(count)"
		return MapDataSet(
			intersections: [
				IntersectionCandidate(
					id: id,
					names: ["Oak Street", "Pine Street"],
					coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
				)
			],
			roads: []
		)
	}
}

struct FakeLocationProvider: LocationProviding {
	var context: DeviceContext

	func currentContext() async throws -> DeviceContext {
		context
	}
}

struct FakeMapDataClient: MapDataFetching {
	func intersections(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) async throws -> [IntersectionCandidate] {
		[
			IntersectionCandidate(
				id: "oak-pine",
				names: ["Oak Street", "Pine Street"],
				coordinate: CLLocationCoordinate2D(latitude: 37.0001, longitude: -122.0)
			)
		]
	}

	func mapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) async throws -> MapDataSet {
		MapDataSet(
			intersections: try await intersections(
				near: coordinate,
				radiusMeters: radiusMeters,
				options: options
			),
			roads: []
		)
	}
}

actor FakeNeighborhoodProvider: NeighborhoodProviding {
	private var count = 0
	private let candidates: [NeighborhoodCandidate]

	var requestCount: Int {
		count
	}

	init(candidates: [NeighborhoodCandidate]) {
		self.candidates = candidates
	}

	func neighborhoods(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [NeighborhoodCandidate] {
		count += 1
		return candidates
	}
}

struct FailingNeighborhoodProvider: NeighborhoodProviding {
	func neighborhoods(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [NeighborhoodCandidate] {
		throw MapDataError.invalidResponse
	}
}
