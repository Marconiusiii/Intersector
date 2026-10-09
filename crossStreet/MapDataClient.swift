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
		URL(string: "https://overpass.private.coffee/api/interpreter")!,
		URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!
	]
	var session: URLSession = .shared
	var minimumCacheDate: Date?
	var responseCache: OverpassRoadResponseCache?
	private var successfulResponses: OverpassRoadResponseCache? { responseCache ?? (requestHandler == nil ? .shared : nil) }
	var requestHandler: (@Sendable (URLRequest) async throws -> MapHTTPResponse)?
	var mapCache = MapDataCache.shared
	var endpointHealth = OverpassEndpointHealth.shared

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
		try await mapCache.data(
			near: coordinate,
			radiusMeters: radiusMeters,
			options: options,
			minimumRequestedAt: minimumCacheDate
		) {
			try await fetchMapData(near: coordinate, radiusMeters: radiusMeters, options: options)
			}
	}

	func freshMapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions()
	) async throws -> MapDataSet {
		try await fetchMapData(near: coordinate, radiusMeters: radiusMeters, options: options, allowsStoredResponse: false)
	}

	func immediateMapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions()
	) async throws -> MapDataSet {
		var coreOptions = options
		coreOptions.includeWalkingPaths = false
		let immediateCoreOptions = coreOptions

		return try await mapCache.data(
			near: coordinate,
			radiusMeters: radiusMeters,
			options: immediateCoreOptions,
			minimumRequestedAt: minimumCacheDate
		) {
			try await fetchMapData(near: coordinate, radiusMeters: radiusMeters, options: immediateCoreOptions)
		}
	}

	func roadMapData(
		near coordinate: CLLocationCoordinate2D,
		roadName: String,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions()
	) async throws -> MapDataSet {
		try await fetchMapData(
			near: coordinate,
			options: options,
			query: focusedRoadQuery(
				near: coordinate,
				roadName: roadName,
				radiusMeters: radiusMeters,
				options: options
			)
		)
	}

	private func fetchMapData(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions,
		allowsStoredResponse: Bool = true
	) async throws -> MapDataSet {
		try await fetchMapData(
			near: coordinate,
			options: options,
			query: roadQuery(near: coordinate, radiusMeters: radiusMeters, options: options),
			area: OverpassMapArea(latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radiusMeters, options: "\(options.includeCrossings)|\(options.includeWalkingPaths)|\(options.includeHighways)"),
			allowsStoredResponse: allowsStoredResponse
		)
	}

	private func fetchMapData(
		near coordinate: CLLocationCoordinate2D,
		options: MapDetailOptions,
		query: String,
		area: OverpassMapArea? = nil,
		allowsStoredResponse: Bool = true
	) async throws -> MapDataSet {
		try Task.checkCancellation()
		if allowsStoredResponse, let area, let cached = await successfulResponses?.response(for: area, minimumRequestedAt: minimumCacheDate) {
			do {
                var result = try decodedMap(cached.data, options: options)
                result.cacheStoredAt = cached.storedAt
                result.cacheRequestedAt = cached.requestedAt
                result.cacheArea = cached.area
                return result
            }
			catch { await successfulResponses?.discard(for: area) }
		}
		let requestedAt = Date()
		let endpoints = await endpointHealth.orderedEndpoints(
			primary: endpoint,
			fallbacks: fallbackEndpoints
		)
		guard !endpoints.isEmpty else {
			LookupDiagnostics.event("map servers", detail: "all endpoints in cooldown")
			throw MapDataError.serversCoolingDown
		}
		var lastError: Error = MapDataError.invalidResponse
		let deadline = LookupDeadline.current ?? ContinuousClock.now.advanced(by: LookupDeadline.requestTimeout)
		for endpoint in endpoints {
			try Task.checkCancellation()
			// An exhausted caller budget must not mark an untried server unhealthy.
			let allowance = try LookupDeadline.serverAllowance(until: deadline)
			LookupDiagnostics.event("map request", detail: "host=\(endpoint.host ?? "unknown"); allowance=\(allowance)")
			do {
				let data = try await LookupAttempt.run(timeout: .seconds(allowance), stage: "map download \(endpoint.host ?? "unknown")") {
					try await fetchMapData(from: endpoint, options: options, query: query, timeout: allowance, area: area, requestedAt: requestedAt)
				}
				try Task.checkCancellation()
				await endpointHealth.markSuccess(endpoint)
				return data
			} catch {
				try Task.checkCancellation()
				lastError = error
				// A lost connection is not evidence that every map server is unhealthy.
				if let urlError = error as? URLError,
				   [.notConnectedToInternet, .networkConnectionLost].contains(urlError.code) {
					throw error
				}
				if case MapDataError.serverError(429) = error {
					await endpointHealth.markTemporaryFailure(endpoint)
					throw error
				}
				guard isTemporary(error) else {
					throw error
				}
				// A local timeout is not a server rejection. Keep it eligible for
				// the next explicit request, while still trying this request's fallback.
				if (error as? URLError)?.code != .timedOut {
					await endpointHealth.markTemporaryFailure(endpoint)
				}
			}
		}
		throw lastError
	}

	private func fetchMapData(
		from endpoint: URL,
		options: MapDetailOptions,
		query: String,
		timeout: TimeInterval,
		area: OverpassMapArea?,
		requestedAt: Date
	) async throws -> MapDataSet {
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = timeout
		request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		request.httpBody = query.data(using: .utf8)

		let httpResult: MapHTTPResponse
		if let requestHandler {
			httpResult = try await requestHandler(request)
		} else {
			let (data, urlResponse) = try await session.data(for: request)
			httpResult = MapHTTPResponse(data: data, response: urlResponse)
		}
		let data = httpResult.data
		let urlResponse = httpResult.response
		guard let httpResponse = urlResponse as? HTTPURLResponse else {
			LookupDiagnostics.event("map response", detail: "non-HTTP response")
			throw MapDataError.invalidResponse
		}
		LookupDiagnostics.event("map response", detail: "host=\(endpoint.host ?? "unknown"); status=\(httpResponse.statusCode); bytes=\(data.count)")
		await endpointHealth.recordResponse(httpResponse)
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw MapDataError.serverError(httpResponse.statusCode == 406 ? 429 : httpResponse.statusCode)
		}
		var result = try decodedMap(data, options: options)
        result.cacheStoredAt = Date()
        result.cacheRequestedAt = requestedAt
        result.cacheArea = area
        try Task.checkCancellation()
        if let area { await successfulResponses?.store(data, for: area, requestedAt: requestedAt) }
        return result
    }

    private func decodedMap(_ data: Data, options: MapDetailOptions) throws -> MapDataSet {
		let response: OverpassResponse
		do {
			response = try JSONDecoder().decode(OverpassResponse.self, from: data)
		} catch {
			LookupDiagnostics.event("map response", detail: "invalid JSON payload")
			throw MapDataError.invalidMapData
		}
		guard response.remark?.isEmpty != false else {
			LookupDiagnostics.event("map response", detail: "server reported incomplete data")
			throw MapDataError.invalidMapData
		}
		try Task.checkCancellation()
		let started = ContinuousClock.now
		defer { LookupDiagnostics.event("map processing", detail: "\(started.duration(to: .now)); \(response.elements.count) elements") }
		return IntersectionBuilder().mapData(from: response, options: options)
	}

	private func isTemporary(_ error: Error) -> Bool {
		if let mapError = error as? MapDataError {
			switch mapError {
			case .serverError(let statusCode):
				return [500, 502, 503, 504].contains(statusCode)
			case .invalidResponse, .invalidMapData:
				return true
			case .serversCoolingDown:
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

	private func roadQuery(
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
		let highwayQuery = options.includeHighways ? """
		  way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"~"^(motorway|motorway_link|trunk|trunk_link)$"];
		""" : ""
		let crossingRadius = Int(min(radiusMeters, 225).rounded())
		let crossingQueries = options.includeCrossings ? """
		  (
		    node(around:\(crossingRadius),\(coordinate.latitude),\(coordinate.longitude))["highway"="crossing"];
		    node(around:\(crossingRadius),\(coordinate.latitude),\(coordinate.longitude))["crossing"];
		  )->.crossingNodes;
		  way(around:\(crossingRadius),\(coordinate.latitude),\(coordinate.longitude))["highway"="footway"]["footway"="crossing"]->.crossingWays;
		  way(bn.crossingNodes)["highway"]->.crossingParentWays;
		  .crossingNodes;
		  .crossingWays;
		  .crossingParentWays;
		""" : ""
		let body = """
		\(OverpassRequestPolicy.querySettings);
		(
		  way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"~"^(\(highwayPattern))$"]["name"];
		\(highwayQuery)
		\(crossingQueries)
		);
		(._;>;);
		out body qt;
		"""
		return encodedBody(body)
	}

	private func focusedRoadQuery(
		near coordinate: CLLocationCoordinate2D,
		roadName: String,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions
	) -> String {
		let radius = Int(radiusMeters.rounded())
		let escapedRoadName = roadName
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		var highwayTypes = [
			"primary", "primary_link", "secondary", "secondary_link", "tertiary",
			"tertiary_link", "unclassified", "residential", "living_street", "pedestrian", "road"
		]
		if options.includeWalkingPaths {
			highwayTypes += ["footway", "path", "steps", "bridleway"]
		}
		let highwayPattern = highwayTypes.joined(separator: "|")
		let crossingRadius = Int(min(radiusMeters, 450).rounded())
		let crossingQueries = options.includeCrossings ? """
		  (
		    node(around:\(crossingRadius),\(coordinate.latitude),\(coordinate.longitude))["highway"="crossing"];
		    node(around:\(crossingRadius),\(coordinate.latitude),\(coordinate.longitude))["crossing"];
		  )->.crossingNodes;
		  way(around:\(crossingRadius),\(coordinate.latitude),\(coordinate.longitude))["highway"="footway"]["footway"="crossing"]->.crossingWays;
		  way(bn.crossingNodes)["highway"]->.crossingParentWays;
		  .crossingNodes;
		  .crossingWays;
		  .crossingParentWays;
		""" : ""
		let body = """
		\(OverpassRequestPolicy.querySettings);
		way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"~"^(\(highwayPattern))$"]["name"="\(escapedRoadName)"]->.currentRoad;
		node(w.currentRoad)->.currentRoadNodes;
		way(bn.currentRoadNodes)["highway"~"^(\(highwayPattern))$"]["name"]->.connectedRoads;
		(.currentRoad;.connectedRoads;
		\(crossingQueries)
		);
		(._;>;);
		out body qt;
		"""
		return encodedBody(body)
	}

	private var userAgent: String {
		let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
		return "Intersector/\(version) (com.marconius.crossStreet; marco@marconius.com)"
	}

	private func encodedBody(_ body: String) -> String {
		let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+"))
		let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
		return "data=\(encoded)"
	}
}

struct MapHTTPResponse: @unchecked Sendable {
	var data: Data
	var response: URLResponse
}

typealias MapEndpointHealth = OverpassEndpointHealth

private extension Array where Element: Hashable {
	nonisolated func removingDuplicates() -> [Element] {
		var seen = Set<Element>()
		return filter { seen.insert($0).inserted }
	}
}

enum MapDataError: LocalizedError {
	case serversCoolingDown
	case invalidResponse
	case serverError(Int)
	case invalidMapData

	var errorDescription: String? {
		switch self {
		case .serversCoolingDown:
			"Map services are temporarily busy. Please wait a minute before trying again."
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
	static let shared = MapDataCache()
	private struct Entry {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var options: MapDetailOptions
		var storedAt: Date
		var requestedAt: Date
		var data: MapDataSet
	}

	private struct InFlightRequest {
		var center: CLLocationCoordinate2D
		var radiusMeters: CLLocationDistance
		var options: MapDetailOptions
		var startedAt: Date
		var task: Task<Void, Never>
		var waiters: [UUID: CheckedContinuation<MapDataSet, Error>]
	}

	private let reuseDistanceMeters: CLLocationDistance = 150
	private let timeToLive: TimeInterval = 300
	private let staleTimeToLive: TimeInterval = 900
	private let maxEntries = 4
	private var entries: [Entry] = []
	private var requests: [UUID: InFlightRequest] = [:]

	var activeWaiterCount: Int { requests.values.reduce(0) { $0 + $1.waiters.count } }

	func data(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance,
		options: MapDetailOptions = MapDetailOptions(),
		minimumRequestedAt: Date? = nil,
		fetch: @escaping @Sendable () async throws -> MapDataSet
	) async throws -> MapDataSet {
		try Task.checkCancellation()
		let earliestRequest = minimumRequestedAt ?? .distantPast
		if let entry = entries.first(where: { entry in
			entry.requestedAt >= earliestRequest && canReuse(entry, for: coordinate, radiusMeters: radiusMeters, options: options) }) {
			LookupDiagnostics.event("map cache", detail: "fresh hit")
			return entry.data
		}
		if let entry = entries.first(where: { entry in
			entry.requestedAt >= earliestRequest && canReuseStale(entry, for: coordinate, radiusMeters: radiusMeters, options: options) }) {
			LookupDiagnostics.event("map cache", detail: "stale hit")
			return entry.data
		}

		let waiterID = UUID()
		let requestID = requests.first(where: {
			$0.value.startedAt >= earliestRequest && canReuse($0.value, for: coordinate, radiusMeters: radiusMeters, options: options)
		})?.key ?? UUID()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { waiter in
				guard !Task.isCancelled else {
					waiter.resume(throwing: CancellationError())
					return
				}
				if requests[requestID] != nil {
					LookupDiagnostics.event("map cache", detail: "joined in-flight request")
					requests[requestID]?.waiters[waiterID] = waiter
					return
				}
				LookupDiagnostics.event("map cache", detail: "miss; starting download")
				let task = Task {
					let result: Result<MapDataSet, Error>
					do {
						let data = try await fetch()
						try Task.checkCancellation()
						result = .success(data)
					} catch {
						result = .failure(error)
					}
					complete(requestID, result: result)
				}
				requests[requestID] = InFlightRequest(
					center: coordinate, radiusMeters: radiusMeters, options: options,
					startedAt: Date(), task: task, waiters: [waiterID: waiter]
				)
			}
		} onCancel: {
			Task { await self.cancelWaiter(waiterID, requestID: requestID) }
		}
	}

	private func cancelWaiter(_ waiterID: UUID, requestID: UUID) {
		guard let waiter = requests[requestID]?.waiters.removeValue(forKey: waiterID) else { return }
		if requests[requestID]?.waiters.isEmpty == true {
			let request = requests.removeValue(forKey: requestID)
			request?.task.cancel()
		}
		waiter.resume(throwing: CancellationError())
	}

	private func complete(_ id: UUID, result: Result<MapDataSet, Error>) {
		// An abandoned request cannot overwrite the cache or finish a newer attempt.
		guard let request = requests.removeValue(forKey: id) else { return }
		if case .success(let data) = result {
			let sourceCenter = data.cacheArea.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? request.center
			store(Entry(center: sourceCenter, radiusMeters: data.cacheArea?.radius ?? request.radiusMeters,
				options: request.options, storedAt: data.cacheStoredAt ?? Date(), requestedAt: data.cacheRequestedAt ?? request.startedAt, data: data))
		}
		for waiter in request.waiters.values { waiter.resume(with: result) }
	}

	private func store(_ entry: Entry) {
		guard !entries.contains(where: {
			$0.options == entry.options && $0.requestedAt > entry.requestedAt &&
				sameArea(center: $0.center, radiusMeters: $0.radiusMeters,
					as: entry.center, requestedRadius: entry.radiusMeters)
		}) else { return }
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
			radiusMeters: entry.radiusMeters,
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
	var remark: String? = nil
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

private extension OverpassElement {
	var coordinate: CLLocationCoordinate2D? {
		guard let lat, let lon else {
			return nil
		}
		return CLLocationCoordinate2D(latitude: lat, longitude: lon)
	}
}

private extension MapRoad {
	var isPublicStreet: Bool {
		IntersectionBuilder.publicStreetHighways.contains(highway)
	}
}

struct IntersectionBuilder {
	private static let streetIntersectionDuplicateRadiusMeters: CLLocationDistance = 30
	private static let cornerCrosswalkAnchorRadiusMeters: CLLocationDistance = 75
	private static let cornerCrosswalkClusterRadiusMeters: CLLocationDistance = 45
	private static let cornerCrosswalkClusterCount = 2

	static let publicStreetHighways: Set<String> = [
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
		let crossingWayNodeIDs = Set(
			response.elements
				.filter { $0.type == "way" && isCrossingWay($0.tags) }
				.flatMap { $0.nodes ?? [] }
		)

		var namesByNode: [Int64: Set<String>] = [:]
		var publicRoadNamesByNode: [Int64: Set<String>] = [:]
		var roads = [MapRoad]()
		for way in response.elements where way.type == "way" {
			guard
				let highway = way.tags?["highway"],
				let wayNodes = way.nodes,
				isAllowedWay(way.tags, options: options)
			else {
				continue
			}
			let name = way.tags?["name"] ?? way.tags?["ref"] ?? ""
			let isHighway = ["motorway", "motorway_link", "trunk", "trunk_link"].contains(highway)
			guard isHighway || way.tags?["name"] != nil else { continue }
			for nodeID in wayNodes where !name.isEmpty && !isHighway {
				namesByNode[nodeID, default: []].insert(name)
				if Self.publicStreetHighways.contains(highway) {
					publicRoadNamesByNode[nodeID, default: []].insert(name)
				}
			}
			roads.append(
				MapRoad(
					id: String(way.id),
					name: name,
					nodeIDs: wayNodes,
					coordinates: wayNodes.compactMap { nodes[$0] },
					highway: highway,
					routeReference: way.tags?["ref"],
					oneWay: way.tags?["oneway"],
					limitedAccess: highway == "motorway" || way.tags?["expressway"] == "yes"
				)
			)
		}

		let evidence = options.includeCrossings
			? crossingEvidence(from: response, roadNodeIDs: Set(publicRoadNamesByNode.keys))
			: [:]
		var intersections = namesByNode.compactMap { entry -> IntersectionCandidate? in
			let (nodeID, names) = entry
			guard names.count >= 2, let coordinate = nodes[nodeID] else {
				return nil
			}
			let nodeTags = response.elements.first(where: { $0.type == "node" && $0.id == nodeID })?.tags
			if (isCrossing(nodeTags) || crossingWayNodeIDs.contains(nodeID)),
			   (publicRoadNamesByNode[nodeID]?.count ?? 0) < 2 {
				return nil
			}
			return IntersectionCandidate(
				id: String(nodeID),
				names: names.sorted(),
				coordinate: coordinate,
				intersectionDetails: intersectionDetails(
					from: evidence[nodeID] ?? [nodeTags ?? [:]], isStreetIntersection: true
				)
			)
		}

		if options.includeCrossings {
			intersections.append(contentsOf: crossingCandidates(
				from: response, roads: roads, streetIntersections: intersections
			))
		}

		return MapDataSet(intersections: intersections, roads: roads)
	}

	func mapData(
		from crossingResponse: OverpassResponse,
		options: MapDetailOptions,
		coreData: MapDataSet
	) -> MapDataSet {
		guard options.includeCrossings else {
			return coreData
		}

		let nodes = Dictionary(uniqueKeysWithValues: crossingResponse.elements
			.filter { $0.type == "node" }.map { ($0.id, $0) })
		let evidence = crossingEvidence(
			from: crossingResponse,
			roadNodeIDs: Set(coreData.roads.filter(\.isPublicStreet).flatMap(\.nodeIDs))
		)
		// Only the identical OSM node can enrich an existing intersection.
		// Nearby corner crossings do not establish which intersection leg has a feature.
		let updatedIntersections = coreData.intersections.map { original in
			var candidate = original
			let isCrossingResult = candidate.id.hasPrefix("crossing-")
			let nodeIDText = isCrossingResult ? String(candidate.id.dropFirst("crossing-".count)) : candidate.id
			if let nodeID = Int64(nodeIDText), let node = nodes[nodeID] {
				candidate.intersectionDetails = intersectionDetails(
					from: evidence[nodeID] ?? [node.tags ?? [:]],
					isStreetIntersection: !isCrossingResult
				)
			}
			return candidate
		}
		let streetIntersections = updatedIntersections.filter { !$0.id.hasPrefix("crossing-") }
		let candidates = crossingCandidates(
			from: crossingResponse, roads: coreData.roads, streetIntersections: streetIntersections
		)
		let existingIDs = Set(coreData.intersections.map(\.id))
		return MapDataSet(
			intersections: updatedIntersections + candidates.filter { !existingIDs.contains($0.id) },
			roads: coreData.roads
		)
	}

	// A crossing belongs to a road only at a shared OSM node. Distance alone
	// cannot establish connectivity between parallel or grade-separated ways.
	private func crossingCandidates(
		from response: OverpassResponse,
		roads: [MapRoad],
		streetIntersections: [IntersectionCandidate]
	) -> [IntersectionCandidate] {
		let nodes = Dictionary(uniqueKeysWithValues: response.elements.filter { $0.type == "node" }.map { ($0.id, $0) })
		let publicRoads = roads.filter(\.isPublicStreet)
		var roadsByNode: [Int64: [MapRoad]] = [:]
		for road in publicRoads {
			for nodeID in road.nodeIDs {
				roadsByNode[nodeID, default: []].append(road)
			}
		}
		let evidence = crossingEvidence(from: response, roadNodeIDs: Set(roadsByNode.keys))
		let crossingCoordinates = evidence.keys.compactMap { nodeID -> CLLocationCoordinate2D? in
			guard let connected = roadsByNode[nodeID], Set(connected.map(\.name)).count == 1 else { return nil }
			return nodes[nodeID]?.coordinate
		}
		return evidence.keys.sorted().compactMap { nodeID in
			guard
				let connected = roadsByNode[nodeID],
				Set(connected.map(\.name)).count == 1,
				let road = connected.first,
				let coordinate = nodes[nodeID]?.coordinate,
				!shouldSuppressCrossing(
					at: coordinate, on: road, streetIntersections: streetIntersections,
					crossingNodeCoordinates: crossingCoordinates
				)
			else { return nil }
			let anchor = nearestIntersection(to: coordinate, on: road.name, in: streetIntersections)
			return IntersectionCandidate(
				id: "crossing-\(nodeID)",
				names: [crossingTitle(on: road.name, near: anchor)],
				coordinate: coordinate,
				associatedRoadNames: [road.name],
				intersectionDetails: intersectionDetails(from: evidence[nodeID] ?? [])
			)
		}
	}

	private func crossingEvidence(
		from response: OverpassResponse,
		roadNodeIDs: Set<Int64>
	) -> [Int64: [[String: String]]] {
		let nodes = Dictionary(uniqueKeysWithValues: response.elements
			.filter { $0.type == "node" }.map { ($0.id, $0) })
		var evidence: [Int64: [[String: String]]] = [:]
		for node in nodes.values where isCrossing(node.tags) {
			evidence[node.id] = [node.tags ?? [:]]
		}
		let paths = response.elements.filter { $0.type == "way" && isCrossingWay($0.tags) }
		for way in paths where hasStrongCrossingEvidence(way.tags) {
			for nodeID in way.nodes ?? [] where roadNodeIDs.contains(nodeID) {
				guard let node = nodes[nodeID], node.tags?["crossing"]?.lowercased() != "no" else { continue }
				if evidence[nodeID] == nil { evidence[nodeID] = [node.tags ?? [:]] }
			}
		}
		// Retain all sources, including negative paths, independent of response order.
		for way in paths {
			for nodeID in way.nodes ?? [] where roadNodeIDs.contains(nodeID) && evidence[nodeID] != nil {
				evidence[nodeID, default: []].append(way.tags ?? [:])
			}
		}
		return evidence
	}

	private func shouldSuppressCrossing(
		at coordinate: CLLocationCoordinate2D,
		on road: MapRoad,
		streetIntersections: [IntersectionCandidate],
		crossingNodeCoordinates: [CLLocationCoordinate2D]
	) -> Bool {
		if streetIntersections.contains(where: {
			Geo.distanceMeters(from: $0.coordinate, to: coordinate) < Self.streetIntersectionDuplicateRadiusMeters
		}) {
			return true
		}

		guard
			let anchor = nearestIntersection(to: coordinate, on: road.name, in: streetIntersections),
			anchor.roadNames.count >= 2,
			Geo.distanceMeters(from: anchor.coordinate, to: coordinate) <= Self.cornerCrosswalkAnchorRadiusMeters
		else {
			return false
		}

		let nearbyCrossingCount = crossingNodeCoordinates.filter {
			Geo.distanceMeters(from: $0, to: coordinate) <= Self.cornerCrosswalkClusterRadiusMeters
		}.count
		return nearbyCrossingCount >= Self.cornerCrosswalkClusterCount
	}

	private func crossingTitle(
		on roadName: String,
		near anchor: IntersectionCandidate?
	) -> String {
		guard let anchor else {
			return "Crossing on \(roadName)"
		}
		return "Crossing on \(roadName) near \(anchor.contextLabel(on: roadName, minimal: true))"
	}

	private func nearestIntersection(
		to coordinate: CLLocationCoordinate2D,
		on roadName: String,
		in intersections: [IntersectionCandidate]
	) -> IntersectionCandidate? {
		intersections
			.filter { $0.roadNames.contains(roadName) }
			.compactMap { intersection -> (intersection: IntersectionCandidate, distance: CLLocationDistance)? in
				let distance = Geo.distanceMeters(from: coordinate, to: intersection.coordinate)
				guard distance <= 100 else {
					return nil
				}
				return (intersection, distance)
			}
			.min { $0.distance < $1.distance }?
			.intersection
	}

	private func isAllowedWay(_ tags: [String: String]?, options: MapDetailOptions) -> Bool {
		guard let highway = tags?["highway"] else {
			return false
		}
		if options.includeHighways, ["motorway", "motorway_link", "trunk", "trunk_link"].contains(highway) {
			return true
		}
		let streetHighways = Self.publicStreetHighways
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

	private func isCrossingWay(_ tags: [String: String]?) -> Bool {
		tags?["highway"] == "footway" && tags?["footway"] == "crossing"
	}

	private func hasStrongCrossingEvidence(_ tags: [String: String]?) -> Bool {
		guard let tags, tags["crossing"]?.lowercased() != "no" else {
			return false
		}
		let crossing = tags["crossing"]?.lowercased()
		let markings = tags["crossing:markings"]?.lowercased()
		return crossing == "traffic_signals" ||
			crossing == "marked" ||
			isPositive(tags["crossing:signals"]) ||
			["zebra", "ladder", "yes"].contains(markings)
	}

	private func isCrossing(_ tags: [String: String]?) -> Bool {
		guard tags?["crossing"]?.lowercased() != "no" else { return false }
		return tags?["highway"] == "crossing" || tags?["crossing"] != nil
	}

	private func intersectionDetails(
		from sources: [[String: String]],
		isStreetIntersection: Bool = false
	) -> IntersectionDetails? {
		let tags = sources.map { $0.mapValues { $0.lowercased() } }
		guard !tags.contains(where: { $0["crossing"] == "no" }) else { return nil }
		let signalValues = tags.compactMap { $0["crossing:signals"] }
		let signalConflict = signalValues.contains { !isPositive($0) } ||
			tags.contains { $0["crossing"] == "uncontrolled" }
		let hasSignal = !signalConflict && tags.contains {
			$0["crossing"] == "traffic_signals" || isPositive($0["crossing:signals"]) ||
			(isStreetIntersection && $0["highway"] == "traffic_signals" && $0["traffic_signals"] == nil)
		}
		let islandValues = tags.compactMap { $0["crossing:island"] }
		let hasIsland = islandValues.allSatisfy { isPositive($0) } && tags.contains {
			$0["crossing"] == "island" || isPositive($0["crossing:island"])
		}
		let details = IntersectionDetails(
			isSignalized: hasSignal,
			hasPedestrianIsland: hasIsland,
			isStreetIntersection: isStreetIntersection
		)
		return details.isEmpty ? nil : details
	}

	private func isPositive(_ value: String?) -> Bool {
		guard let value = value?.lowercased() else {
			return false
		}
		return ["yes", "true", "1"].contains(value)
	}
}
