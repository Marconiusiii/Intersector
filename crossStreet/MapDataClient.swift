//
//  MapDataClient.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Foundation

struct MapDataClient: MapDataFetching {
	var endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
	var fallbackEndpoints = [
		URL(string: "https://overpass.kumi.systems/api/interpreter")!
	]
	var session: URLSession = .shared
	private static let cache = MapDataCache()

	func intersections(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions()
	) async throws -> [IntersectionCandidate] {
		try await mapData(near: coordinate, radiusMeters: radiusMeters, options: options).intersections
	}

	func mapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions()
	) async throws -> MapDataSet {
		try await Self.cache.data(
			near: coordinate,
			radiusMeters: radiusMeters,
			options: options
		) {
			try await fetchMapData(near: coordinate, radiusMeters: radiusMeters, options: options)
		}
	}

	private func fetchMapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) async throws -> MapDataSet {
		let endpoints = ([endpoint] + fallbackEndpoints).removingDuplicates()
		var lastError: Error?

		for endpoint in endpoints {
			do {
				return try await fetchMapData(
					from: endpoint,
					near: coordinate,
					radiusMeters: radiusMeters,
					options: options
				)
			} catch {
				lastError = error
				guard isTemporary(error), endpoint != endpoints.last else {
					throw error
				}
			}
		}

		throw lastError ?? MapDataError.invalidResponse
	}

	private func fetchMapData(
		from endpoint: URL,
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) async throws -> MapDataSet {
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = 10
		request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
		request.httpBody = query(
			near: coordinate,
			radiusMeters: radiusMeters,
			options: options
		).data(using: .utf8)

		let (data, urlResponse) = try await session.data(for: request)
		guard let httpResponse = urlResponse as? HTTPURLResponse else {
			throw MapDataError.invalidResponse
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw MapDataError.serverError(httpResponse.statusCode)
		}
		let response: OverpassResponse
		do {
			response = try JSONDecoder().decode(OverpassResponse.self, from: data)
		} catch {
			throw MapDataError.invalidMapData
		}
		return IntersectionBuilder().mapData(from: response, options: options)
	}

	private func isTemporary(_ error: Error) -> Bool {
		if let mapError = error as? MapDataError {
			switch mapError {
			case .serverError(let statusCode):
				return [429, 500, 502, 503, 504].contains(statusCode)
			case .invalidResponse, .invalidMapData:
				return false
			}
		}

		if let urlError = error as? URLError {
			switch urlError.code {
			case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
				return true
			default:
				return false
			}
		}

		return false
	}

	private func query(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) -> String {
		let radius = Int(radiusMeters.rounded())
		var highwayTypes = [
			"primary",
			"primary_link",
			"secondary",
			"secondary_link",
			"tertiary",
			"tertiary_link",
			"unclassified",
			"residential",
			"living_street",
			"pedestrian",
			"road"
		]
		if options.includeWalkingPaths {
			highwayTypes += [
				"footway",
				"path",
				"steps",
				"bridleway"
			]
		}
		let highwayPattern = highwayTypes.joined(separator: "|")
		let crossingQueries = options.includeCrossings ? """
		  node(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"="crossing"];
		  node(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["crossing"];
		""" : ""
		let body = """
		[out:json][timeout:8];
		(
		  way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"~"^(\(highwayPattern))$"]["name"];
		\(crossingQueries)
		);
		(._;>;);
		out body;
		"""
		let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+"))
		let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
		return "data=\(encoded)"
	}
}

private extension Array where Element: Hashable {
	func removingDuplicates() -> [Element] {
		var seen = Set<Element>()
		return filter { seen.insert($0).inserted }
	}
}

enum MapDataError: LocalizedError {
	case invalidResponse
	case serverError(Int)
	case invalidMapData

	var errorDescription: String? {
		switch self {
		case .invalidResponse:
			"The map server returned an unreadable response."
		case .serverError(let statusCode):
			Self.serverErrorDescription(for: statusCode)
		case .invalidMapData:
			"The map server returned data Intersector could not read."
		}
	}

	private static func serverErrorDescription(for statusCode: Int) -> String {
		switch statusCode {
		case 429:
			"The map server returned error 429, which usually means too many requests."
		case 502, 503:
			"The map server returned error \(statusCode), which usually means it is temporarily unavailable."
		case 504:
			"The map server returned error 504, which usually means the request timed out."
		default:
			"The map server returned error \(statusCode)."
		}
	}
}

actor MapDataCache {
	private struct Entry {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var options: MapDetailOptions
		var storedAt: Date
		var data: MapDataSet
	}

	private struct InFlightRequest {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var options: MapDetailOptions
		var task: Task<MapDataSet, Error>
	}

	private let reuseDistanceMeters: CLLocationDistance = 150
	private let timeToLive: TimeInterval = 300
	private let staleTimeToLive: TimeInterval = 900
	private let maxEntries = 4
	private var entries: [Entry] = []
	private var inFlightRequest: InFlightRequest?

	func data(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions(),
		fetch: @escaping @Sendable () async throws -> MapDataSet
	) async throws -> MapDataSet {
		if let entry = entries.first(where: { canReuse($0, for: coordinate, radiusMeters: radiusMeters, options: options) }) {
			return entry.data
		}

		if let inFlightRequest,
		   canReuse(inFlightRequest, for: coordinate, radiusMeters: radiusMeters, options: options) {
			return try await inFlightRequest.task.value
		}

		let task = Task {
			try await fetch()
		}
		inFlightRequest = InFlightRequest(
			center: coordinate,
			radiusMeters: radiusMeters,
			options: options,
			task: task
		)

		do {
			let data = try await task.value
			store(
				Entry(
					center: coordinate,
					radiusMeters: radiusMeters,
					options: options,
					storedAt: Date(),
					data: data
				)
			)
			inFlightRequest = nil
			return data
		} catch {
			inFlightRequest = nil
			if let entry = entries.first(where: { canReuseStale($0, for: coordinate, radiusMeters: radiusMeters, options: options) }) {
				return entry.data
			}
			throw error
		}
	}

	private func store(_ entry: Entry) {
		entries.removeAll {
			$0.options == entry.options && sameArea(
				center: $0.center,
				radiusMeters: $0.radiusMeters,
				as: entry.center,
				requestedRadius: entry.radiusMeters
			)
		}
		entries.insert(entry, at: 0)
		if entries.count > maxEntries {
			entries.removeLast(entries.count - maxEntries)
		}
	}

	private func canReuse(
		_ entry: Entry,
		for coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) -> Bool {
		guard entry.options == options else {
			return false
		}
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

	private func canReuseStale(
		_ entry: Entry,
		for coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) -> Bool {
		guard entry.options == options else {
			return false
		}
		guard Date().timeIntervalSince(entry.storedAt) <= staleTimeToLive else {
			return false
		}
		return sameArea(
			center: entry.center,
			radiusMeters: max(entry.radiusMeters, radiusMeters),
			as: coordinate,
			requestedRadius: radiusMeters
		)
	}

	private func canReuse(
		_ request: InFlightRequest,
		for coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) -> Bool {
		guard request.options == options else {
			return false
		}
		return sameArea(
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
		let distanceFromCenter = distanceMeters(from: center, to: coordinate)
		let requestedAreaIsCovered = distanceFromCenter + requestedRadius <= radiusMeters
		let centersAreClose = distanceFromCenter <= reuseDistanceMeters
		return requestedAreaIsCovered || (abs(radiusMeters - requestedRadius) < 1 && centersAreClose)
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

	enum CodingKeys: String, CodingKey {
		case type
		case id
		case lat
		case lon
		case nodes
		case tags
	}

	init(
		type: String,
		id: Int64,
		lat: Double?,
		lon: Double?,
		nodes: [Int64]?,
		tags: [String: String]?
	) {
		self.type = type
		self.id = id
		self.lat = lat
		self.lon = lon
		self.nodes = nodes
		self.tags = tags
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		type = try container.decode(String.self, forKey: .type)
		id = try container.decode(Int64.self, forKey: .id)
		lat = try container.decodeIfPresent(Double.self, forKey: .lat)
		lon = try container.decodeIfPresent(Double.self, forKey: .lon)
		nodes = try container.decodeIfPresent([Int64].self, forKey: .nodes)
		tags = try container.decodeIfPresent([String: FlexibleString].self, forKey: .tags)?
			.mapValues(\.value)
	}
}

private struct FlexibleString: Decodable {
	var value: String

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let string = try? container.decode(String.self) {
			value = string
		} else if let int = try? container.decode(Int.self) {
			value = String(int)
		} else if let double = try? container.decode(Double.self) {
			value = String(double)
		} else if let bool = try? container.decode(Bool.self) {
			value = String(bool)
		} else {
			value = ""
		}
	}
}

struct IntersectionBuilder {
	func candidates(
		from response: OverpassResponse,
		options: MapDetailOptions = MapDetailOptions()
	) -> [IntersectionCandidate] {
		mapData(from: response, options: options).intersections
	}

	func mapData(
		from response: OverpassResponse,
		options: MapDetailOptions = MapDetailOptions()
	) -> MapDataSet {
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
				isAllowedWay(way.tags, options: options)
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

		var intersections = namesByNode.compactMap { entry -> IntersectionCandidate? in
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

		if options.includeCrossings {
			let crossingCandidates = response.elements.compactMap { element -> IntersectionCandidate? in
				guard
					element.type == "node",
					isCrossing(element.tags),
					let coordinate = nodes[element.id],
					let roadNames = namesByNode[element.id]?.sorted(),
					roadNames.count == 1,
					let roadName = roadNames.first
				else {
					return nil
				}

				return IntersectionCandidate(
					id: "crossing-\(element.id)",
					names: ["Crossing on \(roadName)"],
					coordinate: coordinate
				)
			}
			intersections.append(contentsOf: crossingCandidates)
		}

		return MapDataSet(intersections: intersections, roads: roads)
	}

	private func isAllowedWay(_ tags: [String: String]?, options: MapDetailOptions) -> Bool {
		guard let highway = tags?["highway"] else {
			return false
		}
		let streetHighways = [
			"primary",
			"primary_link",
			"secondary",
			"secondary_link",
			"tertiary",
			"tertiary_link",
			"unclassified",
			"residential",
			"living_street",
			"pedestrian",
			"road"
		]
		if streetHighways.contains(highway) {
			return true
		}

		guard options.includeWalkingPaths else {
			return false
		}

		return [
			"footway",
			"path",
			"steps",
			"bridleway"
		].contains(highway)
	}

	private func isCrossing(_ tags: [String: String]?) -> Bool {
		tags?["highway"] == "crossing" || tags?["crossing"] != nil || tags?["crossing_ref"] != nil
	}
}
