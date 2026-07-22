//
//  NeighborhoodProvider.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/16/26.
//

import CoreLocation
import Foundation

struct NeighborhoodProvider: NeighborhoodProviding {
	var endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
	var fallbackEndpoints = [
		URL(string: "https://overpass.private.coffee/api/interpreter")!,
		URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!
	]
	var session: URLSession = .shared
	private static let cache = NeighborhoodCache()

	func neighborhoods(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [NeighborhoodCandidate] {
		try await Self.cache.data(
			near: coordinate,
			radiusMeters: radiusMeters
		) {
			try await fetchNeighborhoods(
				near: coordinate,
				radiusMeters: radiusMeters
			)
		}
	}

	private func fetchNeighborhoods(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [NeighborhoodCandidate] {
		let endpoints = uniqueEndpoints([endpoint] + fallbackEndpoints)
		var lastError: Error?

		for endpoint in endpoints {
			do {
				return try await fetchNeighborhoods(
					from: endpoint,
					near: coordinate,
					radiusMeters: radiusMeters
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

	private func uniqueEndpoints(_ endpoints: [URL]) -> [URL] {
		var seen = Set<URL>()
		return endpoints.filter { seen.insert($0).inserted }
	}

	private func fetchNeighborhoods(
		from endpoint: URL,
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [NeighborhoodCandidate] {
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = 12
		request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		request.httpBody = query(
			near: coordinate,
			radiusMeters: radiusMeters
		).data(using: .utf8)

		let (data, urlResponse) = try await session.data(for: request)
		guard let httpResponse = urlResponse as? HTTPURLResponse else {
			throw MapDataError.invalidResponse
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw MapDataError.serverError(httpResponse.statusCode)
		}

		let response: OverpassPlaceResponse
		do {
			response = try JSONDecoder().decode(OverpassPlaceResponse.self, from: data)
		} catch {
			throw MapDataError.invalidMapData
		}

		return NeighborhoodBuilder().candidates(from: response)
	}

	private var userAgent: String {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
		return "Intersector/\(version) (com.marconius.crossStreet; marco@marconius.com)"
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
		radiusMeters: CLLocationDistance
	) -> String {
		let radius = Int(radiusMeters.rounded())
		let body = """
		[out:json][timeout:10];
		(
		  node(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["place"~"^(neighbourhood|quarter|suburb|locality)$"]["name"];
		  way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["place"~"^(neighbourhood|quarter|suburb|locality)$"]["name"];
		  relation(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["place"~"^(neighbourhood|quarter|suburb|locality)$"]["name"];
		  relation(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["boundary"~"^(place|administrative)$"]["name"]["admin_level"~"^(8|9|10|11)$"];
		);
		out center tags;
		"""
		let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+"))
		let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
		return "data=\(encoded)"
	}
}

actor NeighborhoodCache {
	private struct Entry {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var storedAt: Date
		var data: [NeighborhoodCandidate]
	}

	private struct InFlightRequest {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var task: Task<[NeighborhoodCandidate], Error>
	}

	private let reuseDistanceMeters: CLLocationDistance = 250
	private let timeToLive: TimeInterval = 900
	private let maxEntries = 4
	private var entries: [Entry] = []
	private var inFlightRequest: InFlightRequest?

	func data(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		fetch: @escaping @Sendable () async throws -> [NeighborhoodCandidate]
	) async throws -> [NeighborhoodCandidate] {
		if let entry = entries.first(where: { canReuse($0, for: coordinate, radiusMeters: radiusMeters) }) {
			return entry.data
		}

		if let inFlightRequest,
		   sameArea(
		   	center: inFlightRequest.center,
		   	radiusMeters: inFlightRequest.radiusMeters,
		   	as: coordinate,
		   	requestedRadius: radiusMeters
		   ) {
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
			store(
				Entry(
					center: coordinate,
					radiusMeters: radiusMeters,
					storedAt: Date(),
					data: data
				)
			)
			inFlightRequest = nil
			return data
		} catch {
			inFlightRequest = nil
			throw error
		}
	}

	private func store(_ entry: Entry) {
		entries.removeAll {
			sameArea(
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

struct NeighborhoodCandidate: Equatable, Identifiable {
	var id: String
	var name: String
	var coordinate: CLLocationCoordinate2D
	var kind: NeighborhoodKind

	var priority: Int {
		kind.priority
	}
}

enum NeighborhoodKind: String, Equatable {
	case neighbourhood
	case quarter
	case suburb
	case locality
	case administrative
	case placeBoundary

	var priority: Int {
		switch self {
		case .neighbourhood:
			0
		case .quarter:
			1
		case .placeBoundary:
			2
		case .suburb:
			3
		case .locality:
			4
		case .administrative:
			5
		}
	}
}

struct NeighborhoodBuilder {
	func candidates(from response: OverpassPlaceResponse) -> [NeighborhoodCandidate] {
		var seen = Set<String>()
		return response.elements.compactMap { element -> NeighborhoodCandidate? in
			guard
				let name = element.tags?["name"],
				let coordinate = element.coordinate,
				let kind = kind(for: element.tags)
			else {
				return nil
			}
			let dedupeKey = "\(name.lowercased())-\(kind.rawValue)"
			guard seen.insert(dedupeKey).inserted else {
				return nil
			}
			return NeighborhoodCandidate(
				id: "\(element.type)-\(element.id)",
				name: name,
				coordinate: coordinate,
				kind: kind
			)
		}
	}

	private func kind(for tags: [String: String]?) -> NeighborhoodKind? {
		if let place = tags?["place"], let kind = NeighborhoodKind(rawValue: place) {
			return kind
		}

		switch tags?["boundary"] {
		case "place":
			return .placeBoundary
		case "administrative":
			return .administrative
		default:
			return nil
		}
	}
}

struct NeighborhoodResolver {
	func context(
		from candidates: [NeighborhoodCandidate],
		origin: CLLocationCoordinate2D,
		heading: CLLocationDirection?,
		mode: AreaMode
	) -> NeighborhoodContext {
		guard mode != .off else {
			return NeighborhoodContext(area: nil, toward: nil)
		}

		let area = bestNearbyCandidate(from: candidates, origin: origin)?.name
		let toward: String?
		if mode == .toward, let heading {
			toward = bestTowardCandidate(
				from: candidates,
				origin: origin,
				heading: heading
			)?.name
		} else {
			toward = nil
		}

		return NeighborhoodContext(area: area, toward: toward)
	}

	private func bestNearbyCandidate(
		from candidates: [NeighborhoodCandidate],
		origin: CLLocationCoordinate2D
	) -> NeighborhoodCandidate? {
		candidates.min {
			nearbyScore($0, origin: origin) < nearbyScore($1, origin: origin)
		}
	}

	private func bestTowardCandidate(
		from candidates: [NeighborhoodCandidate],
		origin: CLLocationCoordinate2D,
		heading: CLLocationDirection
	) -> NeighborhoodCandidate? {
		let matches: [(candidate: NeighborhoodCandidate, delta: CLLocationDirection)] = candidates
			.map { candidate -> (candidate: NeighborhoodCandidate, delta: CLLocationDirection) in
				let bearing = Geo.bearingDegrees(from: origin, to: candidate.coordinate)
				let delta = IntersectionFinder().angleDelta(from: heading, to: bearing)
				return (candidate, delta)
			}
		return matches
			.filter { match in match.delta <= 70 }
			.min {
				towardScore($0.candidate, origin: origin, delta: $0.delta)
					< towardScore($1.candidate, origin: origin, delta: $1.delta)
			}?
			.candidate
	}

	private func nearbyScore(
		_ candidate: NeighborhoodCandidate,
		origin: CLLocationCoordinate2D
	) -> CLLocationDistance {
		let distance = Geo.distanceMeters(from: origin, to: candidate.coordinate)
		return distance + CLLocationDistance(candidate.priority * 350)
	}

	private func towardScore(
		_ candidate: NeighborhoodCandidate,
		origin: CLLocationCoordinate2D,
		delta: CLLocationDirection
	) -> CLLocationDistance {
		let distance = Geo.distanceMeters(from: origin, to: candidate.coordinate)
		return distance + CLLocationDistance(candidate.priority * 300) + (delta * 20)
	}
}

struct NeighborhoodContext: Equatable {
	var area: String?
	var toward: String?
}

struct OverpassPlaceResponse: Decodable {
	var elements: [OverpassPlaceElement]
}

struct OverpassPlaceElement: Decodable {
	var type: String
	var id: Int64
	var lat: Double?
	var lon: Double?
	var center: OverpassCenter?
	var tags: [String: String]?

	var coordinate: CLLocationCoordinate2D? {
		if let lat, let lon {
			return CLLocationCoordinate2D(latitude: lat, longitude: lon)
		}
		if let center {
			return CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon)
		}
		return nil
	}

	enum CodingKeys: String, CodingKey {
		case type
		case id
		case lat
		case lon
		case center
		case tags
	}

	init(
		type: String,
		id: Int64,
		lat: Double?,
		lon: Double?,
		center: OverpassCenter?,
		tags: [String: String]?
	) {
		self.type = type
		self.id = id
		self.lat = lat
		self.lon = lon
		self.center = center
		self.tags = tags
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		type = try container.decode(String.self, forKey: .type)
		id = try container.decode(Int64.self, forKey: .id)
		lat = try container.decodeIfPresent(Double.self, forKey: .lat)
		lon = try container.decodeIfPresent(Double.self, forKey: .lon)
		center = try container.decodeIfPresent(OverpassCenter.self, forKey: .center)
		tags = try container.decodeIfPresent([String: FlexiblePlaceString].self, forKey: .tags)?
			.mapValues(\.value)
	}
}

struct OverpassCenter: Decodable, Equatable {
	var lat: Double
	var lon: Double
}

private struct FlexiblePlaceString: Decodable {
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
