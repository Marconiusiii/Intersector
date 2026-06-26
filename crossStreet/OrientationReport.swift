//
//  OrientationReport.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import Foundation
import CoreLocation

struct OrientReport: Equatable {
	var kind: ReportKind
	var cross: String
	var dist: String
	var relDir: String?
	var relDegrees: CLLocationDirection?
	var street: String?
	var crossStreet: String? = nil
	var head: String?
	var area: String?
	var toward: String?
	var conf: ConfLev

	func text(with prefs: AppPrefs) -> String {
		text(with: prefs, includeLead: true)
	}

	func text(with prefs: AppPrefs, rank: Int) -> String {
		guard rank > 1 else {
			return text(with: prefs)
		}

		if prefs.detail == .minimal {
			let minimalText: String
			if let street, let crossStreet {
				minimalText = "\(street) and \(crossStreet)"
			} else {
				minimalText = cross
			}
			return "\(leadText(rank: rank)): \(minimalText)."
		}

		return text(with: prefs, includeLead: true, rank: rank)
	}

	func text(with prefs: AppPrefs, includeLead: Bool) -> String {
		text(with: prefs, includeLead: includeLead, rank: nil)
	}

	private func text(with prefs: AppPrefs, includeLead: Bool, rank: Int?) -> String {
		if prefs.detail == .minimal {
			let minimalText: String
			if let street, let crossStreet {
				minimalText = "\(street) and \(crossStreet)"
			} else {
				minimalText = cross
			}
			return minimalText.hasSuffix(".") ? minimalText : "\(minimalText)."
		}

		var text: String
		if
			prefs.intersectionWording == .streetContext,
			let street,
			let crossStreet
		{
			text = "On \(street), \(crossStreet) is about \(dist)"
		} else {
			text = "\(cross), about \(dist)"
		}
		if includeLead {
			text = "\(leadText(rank: rank)): \(text)"
		}
		if let direction = directionText(with: prefs) {
			text += " \(direction)"
		}
		if let area = areaText(prefs) {
			text += " \(area)"
		}
		text += "."
		return text
	}

	private func leadText(rank: Int? = nil) -> String {
		if let rank, rank > 1 {
			return "\(Self.ordinal(rank)) \(baseLeadText)"
		}
		return baseLeadText
	}

	private var baseLeadText: String {
		switch kind {
		case .nearest:
			"Nearest"
		case .upcoming:
			"Upcoming"
		case .scan:
			"Pointed"
		}
	}

	private static func ordinal(_ value: Int) -> String {
		switch value {
		case 2:
			"2nd"
		case 3:
			"3rd"
		default:
			"\(value)th"
		}
	}

	private func areaText(_ prefs: AppPrefs) -> String? {
		guard prefs.detail == .standard else {
			return nil
		}

		return switch prefs.areaMode {
		case .off:
			nil
		case .near:
			area.map { "in \($0)" }
		case .toward:
			if let toward {
				"toward \(toward)"
			} else {
				area.map { "in \($0)" }
			}
		}
	}

	private func directionText(with prefs: AppPrefs) -> String? {
		switch prefs.directionStyle {
		case .words:
			if prefs.manhattanSnobMode, kind != .scan {
				return head.map { "towards \(Geo.manhattanDirection(for: $0))" }
			}
			return relDir
		case .clockFace:
			return relDegrees.map { Self.clockFaceDirection(from: $0) }
		}
	}

	private static func clockFaceDirection(from degrees: CLLocationDirection) -> String {
		let hour = Int((Geo.normalizedDegrees(degrees) + 15) / 30) % 12
		return "at \(hour == 0 ? 12 : hour) o'clock"
	}
}

struct IntersectionReportList: Equatable {
	var reports: [OrientReport]

	func text(with prefs: AppPrefs) -> String {
		guard let first = reports.first else {
			return ""
		}
		if prefs.detail == .minimal {
			let sharedStreet = first.street.flatMap { streetName in
				reports.allSatisfy { $0.street == streetName && $0.crossStreet != nil }
					? streetName
					: nil
			}
			let labels: [String]
			if let sharedStreet {
				labels = reports.enumerated().map { index, report in
					guard let crossStreet = report.crossStreet else {
						return report.cross
					}
					return index == 0 ? "\(sharedStreet) and \(crossStreet)" : crossStreet
				}
			} else {
				labels = reports.map(\.cross)
			}
			return labels.joined(separator: ", ") + "."
		}

		return reports.enumerated().map { index, report in
			report.text(with: prefs, includeLead: index == 0)
		}.joined(separator: " ")
	}
}

enum ReportKind {
	case nearest
	case upcoming
	case scan

	var intentLabel: String {
		switch self {
		case .nearest:
			"nearest intersection"
		case .upcoming:
			"upcoming intersection"
		case .scan:
			"pointed intersection"
		}
	}
}

enum ConfLev {
	case high
	case medium
	case low
}

struct DeviceContext: Equatable {
	var coordinate: CLLocationCoordinate2D
	var headingDegrees: CLLocationDirection?
	var courseDegrees: CLLocationDirection? = nil
	var courseAccuracy: CLLocationDirection? = nil
	var speedMetersPerSecond: CLLocationSpeed? = nil
	var horizontalAccuracy: CLLocationAccuracy? = nil

	var dependableTravelDirection: CLLocationDirection? {
		if
			let courseDegrees,
			let courseAccuracy,
			let speedMetersPerSecond,
			courseDegrees >= 0,
			courseAccuracy >= 0,
			courseAccuracy <= 45,
			speedMetersPerSecond >= 0.7
		{
			return courseDegrees
		}
		return headingDegrees
	}
}

struct IntersectionCandidate: Equatable, Identifiable {
	var id: String
	var names: [String]
	var coordinate: CLLocationCoordinate2D
	var associatedRoadNames: [String] = []

	var title: String {
		names.prefix(2).joined(separator: " and ")
	}

	var roadNames: [String] {
		associatedRoadNames.isEmpty ? names : associatedRoadNames
	}

	func contextLabel(on streetName: String, minimal: Bool) -> String {
		if id.hasPrefix("crossing-") {
			return minimal ? "mapped crossing" : "a mapped crossing"
		}
		let otherNames = names.filter { $0 != streetName }
		return otherNames.isEmpty ? title : otherNames.joined(separator: " and ")
	}
}

struct StreetPositionContext: Equatable {
	var streetName: String
	var boundaries: [IntersectionCandidate]
	var following: IntersectionCandidate?
	var isOnStreet: Bool

	func text(with prefs: AppPrefs) -> String {
		if prefs.detail == .minimal {
			let candidates = boundaries + [following].compactMap { $0 }
			let allShareStreet = candidates.allSatisfy { $0.names.contains(streetName) }
			let labels: [String]
			if allShareStreet, let first = candidates.first {
				labels = [first.title] + candidates.dropFirst().map {
					$0.contextLabel(on: streetName, minimal: true)
				}
			} else {
				labels = candidates.map(\.title)
			}
			return labels.joined(separator: ", ") + "."
		}

		guard boundaries.count == 2 else {
			return ""
		}
		let prefix = isOnStreet ? "On" : "Along"
		let first = boundaries[0].contextLabel(on: streetName, minimal: false)
		let second = boundaries[1].contextLabel(on: streetName, minimal: false)
		var text = "\(prefix) \(streetName) between \(first) and \(second)"
		if let following {
			text += ", toward \(following.contextLabel(on: streetName, minimal: false))"
		}
		return text + "."
	}
}

struct MapRoad: Equatable, Identifiable {
	var id: String
	var name: String
	var nodeIDs: [Int64]
	var coordinates: [CLLocationCoordinate2D]
}

struct MapDataSet: Equatable {
	var intersections: [IntersectionCandidate]
	var roads: [MapRoad]

	func currentStreetIntersections(from coordinate: CLLocationCoordinate2D) -> [IntersectionCandidate] {
		guard let road = nearestRoad(to: coordinate) else {
			return []
		}
		return intersections
			.filter { !$0.id.hasPrefix("crossing-") && $0.roadNames.contains(road.name) }
			.sorted {
				Geo.distanceMeters(from: coordinate, to: $0.coordinate)
					< Geo.distanceMeters(from: coordinate, to: $1.coordinate)
			}
	}

	func streetPosition(
		from context: DeviceContext,
		count: SpokenIntersectionCount
	) -> StreetPositionContext? {
		guard count != .one, let road = nearestRoad(to: context.coordinate) else {
			return nil
		}
		let candidates = IntersectionFinder().rankedNearest(
			from: context.coordinate,
			in: intersections.filter { $0.roadNames.contains(road.name) }
		)
		let positioned = candidates.compactMap { candidate -> (IntersectionCandidate, Double)? in
			guard let distance = road.signedDistanceAlongRoad(
				from: context.coordinate,
				to: candidate.coordinate
			) else {
				return nil
			}
			return (candidate, distance)
		}
		let negative = positioned.filter { $0.1 < -3 }.sorted { abs($0.1) < abs($1.1) }
		let positive = positioned.filter { $0.1 > 3 }.sorted { abs($0.1) < abs($1.1) }
		guard let negativeBoundary = negative.first, let positiveBoundary = positive.first else {
			return nil
		}

		var following: IntersectionCandidate?
		if
			count == .three,
			let direction = context.dependableTravelDirection,
			let directionSign = road.directionSign(for: direction, at: context.coordinate)
		{
			let forward = directionSign >= 0 ? positive : negative
			following = forward.dropFirst().first?.0
		}

		let roadDistance = road.minimumDistance(to: context.coordinate)
		let accuracy = context.horizontalAccuracy ?? 25
		let onStreetThreshold = max(20, min(accuracy, 50))
		return StreetPositionContext(
			streetName: road.name,
			boundaries: [negativeBoundary.0, positiveBoundary.0],
			following: following,
			isOnStreet: roadDistance <= onStreetThreshold
		)
	}

	func nearestRoadName(
		to coordinate: CLLocationCoordinate2D,
		matching roadNames: [String]
	) -> String? {
		let allowedNames = Set(roadNames)
		return roads
			.filter { allowedNames.contains($0.name) }
			.min {
				$0.minimumDistance(to: coordinate) < $1.minimumDistance(to: coordinate)
			}?
			.name
	}

	private func nearestRoad(to coordinate: CLLocationCoordinate2D) -> MapRoad? {
		roads.min {
			$0.minimumDistance(to: coordinate) < $1.minimumDistance(to: coordinate)
		}
	}
}

extension MapRoad {
	func minimumDistance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
		guard coordinates.count > 1 else {
			return coordinates.first.map {
				Geo.distanceMeters(from: coordinate, to: $0)
			} ?? .greatestFiniteMagnitude
		}

		return zip(coordinates, coordinates.dropFirst())
			.map { start, end in
				Self.distance(
					from: coordinate,
					toSegmentFrom: start,
					to: end
				)
			}
			.min() ?? .greatestFiniteMagnitude
	}

	func signedDistanceAlongRoad(
		from origin: CLLocationCoordinate2D,
		to target: CLLocationCoordinate2D
	) -> CLLocationDistance? {
		guard let reference = nearestSegmentReference(to: origin) else {
			return nil
		}
		let targetVector = Self.localVector(from: origin, to: target)
		return targetVector.x * reference.tangentX + targetVector.y * reference.tangentY
	}

	func directionSign(
		for heading: CLLocationDirection,
		at coordinate: CLLocationCoordinate2D
	) -> Double? {
		guard let reference = nearestSegmentReference(to: coordinate) else {
			return nil
		}
		let radians = heading * Double.pi / 180
		let headingX = sin(radians)
		let headingY = cos(radians)
		return headingX * reference.tangentX + headingY * reference.tangentY
	}

	private func nearestSegmentReference(to coordinate: CLLocationCoordinate2D) -> SegmentReference? {
		zip(coordinates, coordinates.dropFirst())
			.compactMap { start, end in
				Self.segmentReference(from: coordinate, start: start, end: end)
			}
			.min { $0.distance < $1.distance }
	}

	private struct SegmentReference {
		var distance: CLLocationDistance
		var tangentX: Double
		var tangentY: Double
	}

	private static func segmentReference(
		from coordinate: CLLocationCoordinate2D,
		start: CLLocationCoordinate2D,
		end: CLLocationCoordinate2D
	) -> SegmentReference? {
		let startVector = localVector(from: coordinate, to: start)
		let endVector = localVector(from: coordinate, to: end)
		let segmentX = endVector.x - startVector.x
		let segmentY = endVector.y - startVector.y
		let segmentLength = hypot(segmentX, segmentY)
		guard segmentLength > 0 else {
			return nil
		}
		let segmentLengthSquared = segmentLength * segmentLength
		let projection = -(startVector.x * segmentX + startVector.y * segmentY) / segmentLengthSquared
		let clampedProjection = min(1, max(0, projection))
		let closestX = startVector.x + clampedProjection * segmentX
		let closestY = startVector.y + clampedProjection * segmentY
		return SegmentReference(
			distance: hypot(closestX, closestY),
			tangentX: segmentX / segmentLength,
			tangentY: segmentY / segmentLength
		)
	}

	private static func localVector(
		from origin: CLLocationCoordinate2D,
		to target: CLLocationCoordinate2D
	) -> (x: Double, y: Double) {
		let earthRadius = 6_371_000.0
		let latitudeScale = Double.pi / 180
		let longitudeScale = latitudeScale * cos(origin.latitude * latitudeScale)
		return (
			(target.longitude - origin.longitude) * longitudeScale * earthRadius,
			(target.latitude - origin.latitude) * latitudeScale * earthRadius
		)
	}

	private static func distance(
		from coordinate: CLLocationCoordinate2D,
		toSegmentFrom start: CLLocationCoordinate2D,
		to end: CLLocationCoordinate2D
	) -> CLLocationDistance {
		let earthRadius = 6_371_000.0
		let latitudeScale = Double.pi / 180
		let longitudeScale = latitudeScale * cos(coordinate.latitude * latitudeScale)
		let startX = (start.longitude - coordinate.longitude) * longitudeScale * earthRadius
		let startY = (start.latitude - coordinate.latitude) * latitudeScale * earthRadius
		let endX = (end.longitude - coordinate.longitude) * longitudeScale * earthRadius
		let endY = (end.latitude - coordinate.latitude) * latitudeScale * earthRadius
		let segmentX = endX - startX
		let segmentY = endY - startY
		let segmentLengthSquared = segmentX * segmentX + segmentY * segmentY

		guard segmentLengthSquared > 0 else {
			return hypot(startX, startY)
		}

		let projection = -(startX * segmentX + startY * segmentY) / segmentLengthSquared
		let clampedProjection = min(1, max(0, projection))
		let closestX = startX + clampedProjection * segmentX
		let closestY = startY + clampedProjection * segmentY
		return hypot(closestX, closestY)
	}
}

extension CLLocationCoordinate2D: @retroactive Equatable {
	public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
		lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
	}
}
