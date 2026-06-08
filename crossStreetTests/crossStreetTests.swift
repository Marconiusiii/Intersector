//
//  crossStreetTests.swift
//  crossStreetTests
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Testing
@testable import crossStreet

struct crossStreetTests {
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
}
