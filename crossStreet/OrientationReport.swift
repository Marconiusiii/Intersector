//
//  OrientationReport.swift
//  crossStreet
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
	var street: String?
	var head: String?
	var area: String?
	var toward: String?
	var conf: ConfLev

	func text(with prefs: AppPrefs) -> String {
		var parts = [leadText]
		parts.append("\(cross), about \(dist)")
		if let relDir {
			parts.append(relDir)
		}
		if prefs.detail == .standard, let street, let head {
			parts.append("appears \(head) along \(street)")
		}
		if let area = areaText(prefs) {
			parts.append(area)
		}
		if conf != .high {
			parts.append(conf.text)
		}
		return parts.joined(separator: ". ") + "."
	}

	private var leadText: String {
		switch kind {
		case .nearest:
			"Nearest intersection"
		case .upcoming:
			"Upcoming intersection"
		case .scan:
			"Pointed intersection"
		}
	}

	private func areaText(_ prefs: AppPrefs) -> String? {
		switch prefs.areaMode {
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

	var text: String {
		switch self {
		case .high:
			""
		case .medium:
			"Direction is an estimate"
		case .low:
			"Direction is uncertain"
		}
	}
}

struct DeviceContext: Equatable {
	var coordinate: CLLocationCoordinate2D
	var headingDegrees: CLLocationDirection?
}

struct IntersectionCandidate: Equatable, Identifiable {
	var id: String
	var names: [String]
	var coordinate: CLLocationCoordinate2D

	var title: String {
		names.prefix(2).joined(separator: " and ")
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
			.filter { $0.names.contains(road.name) }
			.sorted {
				Geo.distanceMeters(from: coordinate, to: $0.coordinate)
					< Geo.distanceMeters(from: coordinate, to: $1.coordinate)
			}
	}

	private func nearestRoad(to coordinate: CLLocationCoordinate2D) -> MapRoad? {
		roads.min {
			$0.minimumDistance(to: coordinate) < $1.minimumDistance(to: coordinate)
		}
	}
}

extension MapRoad {
	func minimumDistance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
		coordinates
			.map { Geo.distanceMeters(from: coordinate, to: $0) }
			.min() ?? .greatestFiniteMagnitude
	}
}

extension CLLocationCoordinate2D: @retroactive Equatable {
	public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
		lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
	}
}
