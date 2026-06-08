//
//  MapDataClient.swift
//  crossStreet
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Foundation

struct MapDataClient: MapDataFetching {
	var endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
	var session: URLSession = .shared
	private static let cache = MapDataCache()

	func intersections(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [IntersectionCandidate] {
		try await mapData(near: coordinate, radiusMeters: radiusMeters).intersections
	}

	func mapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> MapDataSet {
		try await Self.cache.data(
			near: coordinate,
			radiusMeters: radiusMeters
		) {
			try await fetchMapData(near: coordinate, radiusMeters: radiusMeters)
		}
	}

	private func fetchMapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> MapDataSet {
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
		request.httpBody = query(
			near: coordinate,
			radiusMeters: radiusMeters
		).data(using: .utf8)

		let (data, _) = try await session.data(for: request)
		let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
		return IntersectionBuilder().mapData(from: response)
	}

	private func query(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) -> String {
		let radius = Int(radiusMeters.rounded())
		let body = """
		[out:json][timeout:8];
		way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"]["highway"!~"^(motorway|motorway_link|trunk|trunk_link)$"]["name"];
		(._;>;);
		out body;
		"""
		let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+"))
		let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
		return "data=\(encoded)"
	}
}

actor MapDataCache {
	private struct Entry {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var storedAt: Date
		var data: MapDataSet
	}

	private struct InFlightRequest {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var task: Task<MapDataSet, Error>
	}

	private let reuseDistanceMeters: CLLocationDistance = 100
	private let timeToLive: TimeInterval = 300
	private var entry: Entry?
	private var inFlightRequest: InFlightRequest?

	func data(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		fetch: @escaping @Sendable () async throws -> MapDataSet
	) async throws -> MapDataSet {
		if let entry, canReuse(entry, for: coordinate, radiusMeters: radiusMeters) {
			return entry.data
		}

		if let inFlightRequest,
		   canReuse(inFlightRequest, for: coordinate, radiusMeters: radiusMeters) {
			return try await inFlightRequest.task.value
		}

		let task = Task {
			try await fetch()
		}
		inFlightRequest = InFlightRequest(
			center: coordinate,
			radiusMeters: radiusMeters,
			task: task
		)

		do {
			let data = try await task.value
			entry = Entry(
				center: coordinate,
				radiusMeters: radiusMeters,
				storedAt: Date(),
				data: data
			)
			inFlightRequest = nil
			return data
		} catch {
			inFlightRequest = nil
			throw error
		}
	}

	private func canReuse(
		_ entry: Entry,
		for coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) -> Bool {
		guard Date().timeIntervalSince(entry.storedAt) <= timeToLive else {
			return false
		}
		return sameArea(
			center: entry.center,
			radiusMeters: entry.radiusMeters,
			as: coordinate,
			requestedRadius: radiusMeters
		)
	}

	private func canReuse(
		_ request: InFlightRequest,
		for coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) -> Bool {
		sameArea(
			center: request.center,
			radiusMeters: request.radiusMeters,
			as: coordinate,
			requestedRadius: radiusMeters
		)
	}

	private func sameArea(
		center: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		as coordinate: CLLocationCoordinate2D,
		requestedRadius: CLLocationDistance
	) -> Bool {
		abs(radiusMeters - requestedRadius) < 1
			&& distanceMeters(from: center, to: coordinate) <= reuseDistanceMeters
	}

	private func distanceMeters(
		from start: CLLocationCoordinate2D,
		to end: CLLocationCoordinate2D
	) -> CLLocationDistance {
		CLLocation(latitude: start.latitude, longitude: start.longitude)
			.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
	}
}

struct OverpassResponse: Decodable {
	var elements: [OverpassElement]
}

struct OverpassElement: Decodable {
	var type: String
	var id: Int64
	var lat: Double?
	var lon: Double?
	var nodes: [Int64]?
	var tags: [String: String]?
}

struct IntersectionBuilder {
	func candidates(from response: OverpassResponse) -> [IntersectionCandidate] {
		mapData(from: response).intersections
	}

	func mapData(from response: OverpassResponse) -> MapDataSet {
		let nodes = Dictionary(
			uniqueKeysWithValues: response.elements.compactMap { element -> (Int64, CLLocationCoordinate2D)? in
				guard element.type == "node", let lat = element.lat, let lon = element.lon else {
					return nil
				}
				return (element.id, CLLocationCoordinate2D(latitude: lat, longitude: lon))
			}
		)

		var namesByNode: [Int64: Set<String>] = [:]
		var roads = [MapRoad]()
		for way in response.elements where way.type == "way" {
			guard
				let name = way.tags?["name"],
				let wayNodes = way.nodes,
				isWalkableRoad(way.tags)
			else {
				continue
			}
			for nodeID in wayNodes {
				namesByNode[nodeID, default: []].insert(name)
			}
			roads.append(
				MapRoad(
					id: String(way.id),
					name: name,
					nodeIDs: wayNodes,
					coordinates: wayNodes.compactMap { nodes[$0] }
				)
			)
		}

		let intersections = namesByNode.compactMap { entry -> IntersectionCandidate? in
			let (nodeID, names) = entry
			guard names.count >= 2, let coordinate = nodes[nodeID] else {
				return nil
			}
			return IntersectionCandidate(
				id: String(nodeID),
				names: names.sorted(),
				coordinate: coordinate
			)
		}

		return MapDataSet(intersections: intersections, roads: roads)
	}

	private func isWalkableRoad(_ tags: [String: String]?) -> Bool {
		guard let highway = tags?["highway"] else {
			return false
		}
		return !["motorway", "motorway_link", "trunk", "trunk_link"].contains(highway)
	}
}
