//
//  WatchOrientationService.swift
//  Intersector Watch App
//
//  Created by Marco Salsiccia on 6/17/26.
//

import CoreLocation
import Foundation

enum WatchReportKind {
	case nearest
	case upcoming

	var leadText: String {
		switch self {
		case .nearest:
			"Nearest"
		case .upcoming:
			"Upcoming"
		}
	}

	var intentLabel: String {
		switch self {
		case .nearest:
			"nearest intersection"
		case .upcoming:
			"upcoming intersection"
		}
	}
}

enum WatchReportError: LocalizedError {
	case noIntersections
	case locationUnavailable
	case invalidMapData
	case invalidResponse
	case serverError(Int)

	var errorDescription: String? {
		switch self {
		case .noIntersections:
			"No nearby mapped intersections were found."
		case .locationUnavailable:
			"Location is not available yet. Try again."
		case .invalidMapData:
			"The map server returned data Intersector could not read."
		case .invalidResponse:
			"The map server returned an unreadable response."
		case .serverError(let statusCode):
			"The map server returned error \(statusCode)."
		}
	}
}

enum IntersectorWatchReporter {
	@MainActor
	static func reportText(for kind: WatchReportKind) async -> String {
		do {
			let report = try await WatchOrientationService().report(kind)
			return report.text
		} catch {
			return "Unable to update \(kind.intentLabel). \(error.localizedDescription)"
		}
	}
}

struct WatchOrientationService {
	private let locationProvider = WatchLocationProvider()
	private let mapClient = WatchMapDataClient()
	private let finder = WatchIntersectionFinder()

	@MainActor
	func report(_ kind: WatchReportKind) async throws -> WatchOrientationReport {
		let context = try await locationProvider.currentContext()
		let intersections = try await mapClient.intersections(
			near: context.coordinate,
			radiusMeters: kind == .upcoming ? 375 : 225
		)
		guard let match = finder.bestMatch(for: kind, from: context, in: intersections) else {
			throw WatchReportError.noIntersections
		}
		let distance = WatchGeo.distanceMeters(from: context.coordinate, to: match.coordinate)
		let bearing = WatchGeo.bearingDegrees(from: context.coordinate, to: match.coordinate)
		let direction = relativeDirection(
			bearing: bearing,
			heading: context.headingDegrees,
			kind: kind
		)
		return WatchOrientationReport(
			kind: kind,
			title: match.title,
			distance: WatchGeo.spokenDistance(distance),
			direction: direction
		)
	}

	private func relativeDirection(
		bearing: CLLocationDirection,
		heading: CLLocationDirection?,
		kind: WatchReportKind
	) -> String? {
		guard let heading else {
			return kind == .nearest ? WatchGeo.compassDirection(bearing) : nil
		}
		let degrees = WatchGeo.normalizedDegrees(bearing - heading)
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
}

struct WatchOrientationReport {
	var kind: WatchReportKind
	var title: String
	var distance: String
	var direction: String?

	var text: String {
		var text = "\(kind.leadText): \(title), about \(distance)"
		if let direction {
			text += " \(direction)"
		}
		return text + "."
	}
}

struct WatchDeviceContext {
	var coordinate: CLLocationCoordinate2D
	var headingDegrees: CLLocationDirection?
}

struct WatchIntersectionCandidate: Identifiable {
	var id: String
	var names: [String]
	var coordinate: CLLocationCoordinate2D

	var title: String {
		names.prefix(2).joined(separator: " and ")
	}
}

@MainActor
final class WatchLocationProvider: NSObject, CLLocationManagerDelegate {
	private let manager = CLLocationManager()
	private var continuation: CheckedContinuation<WatchDeviceContext, Error>?
	private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
	private var latestHeading: CLLocationDirection?

	override init() {
		super.init()
		manager.delegate = self
		manager.desiredAccuracy = kCLLocationAccuracyBest
		manager.distanceFilter = kCLDistanceFilterNone
		manager.headingFilter = 5
	}

	func currentContext() async throws -> WatchDeviceContext {
		if CLLocationManager.headingAvailable() {
			manager.startUpdatingHeading()
		}

		switch manager.authorizationStatus {
		case .notDetermined:
			let status = await requestWhenInUseAuthorization()
			guard status == .authorizedAlways || status == .authorizedWhenInUse else {
				throw WatchReportError.locationUnavailable
			}
		case .authorizedAlways, .authorizedWhenInUse:
			break
		case .denied, .restricted:
			throw WatchReportError.locationUnavailable
		@unknown default:
			throw WatchReportError.locationUnavailable
		}

		return try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			manager.startUpdatingLocation()
		}
	}

	private func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
		switch manager.authorizationStatus {
		case .notDetermined:
			return await withCheckedContinuation { continuation in
				authorizationContinuation = continuation
				manager.requestWhenInUseAuthorization()
			}
		default:
			return manager.authorizationStatus
		}
	}

	func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
		if let authorizationContinuation {
			self.authorizationContinuation = nil
			authorizationContinuation.resume(returning: manager.authorizationStatus)
		}
	}

	func locationManager(
		_ manager: CLLocationManager,
		didUpdateLocations locations: [CLLocation]
	) {
		guard let location = locations.first(where: { $0.horizontalAccuracy >= 0 }) else {
			finish(.failure(WatchReportError.locationUnavailable))
			return
		}
		finish(
			.success(
				WatchDeviceContext(
					coordinate: location.coordinate,
					headingDegrees: latestHeading
				)
			)
		)
	}

	func locationManager(
		_ manager: CLLocationManager,
		didFailWithError error: Error
	) {
		finish(.failure(error))
	}

	func locationManager(
		_ manager: CLLocationManager,
		didUpdateHeading newHeading: CLHeading
	) {
		let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
		latestHeading = heading >= 0 ? heading : nil
	}

	private func finish(_ result: Result<WatchDeviceContext, Error>) {
		guard let continuation else {
			return
		}
		self.continuation = nil
		manager.stopUpdatingLocation()
		switch result {
		case .success(let context):
			continuation.resume(returning: context)
		case .failure(let error):
			continuation.resume(throwing: error)
		}
	}
}

struct WatchMapDataClient {
	private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
	private let session: URLSession = .shared

	func intersections(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) async throws -> [WatchIntersectionCandidate] {
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = 10
		request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
		request.httpBody = query(
			near: coordinate,
			radiusMeters: radiusMeters
		).data(using: .utf8)

		let (data, urlResponse) = try await session.data(for: request)
		guard let httpResponse = urlResponse as? HTTPURLResponse else {
			throw WatchReportError.invalidResponse
		}
		guard (200..<300).contains(httpResponse.statusCode) else {
			throw WatchReportError.serverError(httpResponse.statusCode)
		}
		let response: WatchOverpassResponse
		do {
			response = try JSONDecoder().decode(WatchOverpassResponse.self, from: data)
		} catch {
			throw WatchReportError.invalidMapData
		}
		return WatchIntersectionBuilder().candidates(from: response)
	}

	private func query(
		near coordinate: CLLocationCoordinate2D,
		radiusMeters: CLLocationDistance
	) -> String {
		let radius = Int(radiusMeters.rounded())
		let body = """
		[out:json][timeout:8];
		way(around:\(radius),\(coordinate.latitude),\(coordinate.longitude))["highway"~"^(primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|pedestrian|road)$"]["name"];
		(._;>;);
		out body;
		"""
		let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+"))
		let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
		return "data=\(encoded)"
	}
}

struct WatchOverpassResponse: Decodable {
	var elements: [WatchOverpassElement]
}

struct WatchOverpassElement: Decodable {
	var type: String
	var id: Int64
	var lat: Double?
	var lon: Double?
	var nodes: [Int64]?
	var tags: [String: String]?
}

struct WatchIntersectionBuilder {
	func candidates(from response: WatchOverpassResponse) -> [WatchIntersectionCandidate] {
		let nodes = Dictionary(
			uniqueKeysWithValues: response.elements.compactMap { element -> (Int64, CLLocationCoordinate2D)? in
				guard element.type == "node", let lat = element.lat, let lon = element.lon else {
					return nil
				}
				return (element.id, CLLocationCoordinate2D(latitude: lat, longitude: lon))
			}
		)
		var namesByNode: [Int64: Set<String>] = [:]
		for way in response.elements where way.type == "way" {
			guard
				let name = way.tags?["name"],
				let wayNodes = way.nodes,
				isStreet(way.tags)
			else {
				continue
			}
			for nodeID in wayNodes {
				namesByNode[nodeID, default: []].insert(name)
			}
		}
		return namesByNode.compactMap { entry -> WatchIntersectionCandidate? in
			let (nodeID, names) = entry
			guard names.count >= 2, let coordinate = nodes[nodeID] else {
				return nil
			}
			return WatchIntersectionCandidate(
				id: String(nodeID),
				names: names.sorted(),
				coordinate: coordinate
			)
		}
	}

	private func isStreet(_ tags: [String: String]?) -> Bool {
		guard let highway = tags?["highway"] else {
			return false
		}
		return [
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
		].contains(highway)
	}
}

struct WatchIntersectionFinder {
	func bestMatch(
		for kind: WatchReportKind,
		from context: WatchDeviceContext,
		in candidates: [WatchIntersectionCandidate]
	) -> WatchIntersectionCandidate? {
		switch kind {
		case .nearest:
			return candidates.min {
				WatchGeo.distanceMeters(from: context.coordinate, to: $0.coordinate)
					< WatchGeo.distanceMeters(from: context.coordinate, to: $1.coordinate)
			}
		case .upcoming:
			guard let heading = context.headingDegrees else {
				return candidates.min {
					WatchGeo.distanceMeters(from: context.coordinate, to: $0.coordinate)
						< WatchGeo.distanceMeters(from: context.coordinate, to: $1.coordinate)
				}
			}
			let ahead = candidates.filter { candidate in
				let bearing = WatchGeo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				return angleDelta(from: heading, to: bearing) <= 60
			}
			return (ahead.isEmpty ? candidates : ahead).min {
				WatchGeo.distanceMeters(from: context.coordinate, to: $0.coordinate)
					< WatchGeo.distanceMeters(from: context.coordinate, to: $1.coordinate)
			}
		}
	}

	private func angleDelta(
		from heading: CLLocationDirection,
		to bearing: CLLocationDirection
	) -> CLLocationDirection {
		let delta = abs(WatchGeo.normalizedDegrees(bearing - heading))
		return min(delta, 360 - delta)
	}
}

enum WatchGeo {
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
