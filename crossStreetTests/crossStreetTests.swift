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
			street: "Oak Street",
			head: "north",
			area: "Downtown",
			toward: nil,
			conf: .high
		)

		let text = report.text(with: prefs)

		#expect(text.contains("Nearest intersection"))
		#expect(text.contains("Oak Street and Pine Street"))
		#expect(!text.contains("Downtown"))
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
