//
//  AppPrefs.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import Foundation

struct AppPrefs {
	var areaMode = AreaMode.near
	var detail = DetailLev.standard
	var measurementUnit = MeasurementUnit.feet
	var directionStyle = DirectionStyle.words
	var intersectionWording = IntersectionWording.direct
	var spokenIntersectionCount = SpokenIntersectionCount.one
	var mapDetails = MapDetailOptions()
	var haptics = true

	nonisolated init(
		areaMode: AreaMode = .near,
		detail: DetailLev = .standard,
		measurementUnit: MeasurementUnit = .feet,
		directionStyle: DirectionStyle = .words,
		intersectionWording: IntersectionWording = .direct,
		spokenIntersectionCount: SpokenIntersectionCount = .one,
		mapDetails: MapDetailOptions = MapDetailOptions(),
		haptics: Bool = true
	) {
		self.areaMode = areaMode
		self.detail = detail
		self.measurementUnit = measurementUnit
		self.directionStyle = directionStyle
		self.intersectionWording = intersectionWording
		self.spokenIntersectionCount = spokenIntersectionCount
		self.mapDetails = mapDetails
		self.haptics = haptics
	}

	@MainActor
	static func saved(from defaults: UserDefaults = .standard) -> AppPrefs {
		AppPrefs(
			areaMode: AreaMode(rawValue: defaults.string(forKey: "areaMode") ?? "") ?? .near,
			detail: DetailLev(rawValue: defaults.string(forKey: "detailLevel") ?? "") ?? .standard,
			measurementUnit: MeasurementUnit(rawValue: defaults.string(forKey: "measurementUnit") ?? "") ?? .feet,
			directionStyle: DirectionStyle(rawValue: defaults.string(forKey: "directionStyle") ?? "") ?? .words,
			intersectionWording: IntersectionWording(
				rawValue: defaults.string(forKey: "intersectionWording") ?? ""
			) ?? .direct,
			spokenIntersectionCount: SpokenIntersectionCount(
				rawValue: defaults.integer(forKey: "spokenIntersectionCount")
			) ?? .one,
			mapDetails: MapDetailOptions(
				includeCrossings: defaults.object(forKey: "includeCrossings") as? Bool ?? false,
				includeWalkingPaths: defaults.object(forKey: "includeWalkingPaths") as? Bool ?? false
			),
			haptics: defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
		)
	}
}

struct MapDetailOptions: Equatable, Hashable, Sendable {
	var includeCrossings = false
	var includeWalkingPaths = false

	nonisolated init(
		includeCrossings: Bool = false,
		includeWalkingPaths: Bool = false
	) {
		self.includeCrossings = includeCrossings
		self.includeWalkingPaths = includeWalkingPaths
	}

	nonisolated static func == (lhs: MapDetailOptions, rhs: MapDetailOptions) -> Bool {
		lhs.includeCrossings == rhs.includeCrossings &&
			lhs.includeWalkingPaths == rhs.includeWalkingPaths
	}

	nonisolated func hash(into hasher: inout Hasher) {
		hasher.combine(includeCrossings)
		hasher.combine(includeWalkingPaths)
	}
}

enum AreaMode: String, CaseIterable, Identifiable {
	case off
	case near
	case toward

	var id: String { rawValue }

	var label: String {
		switch self {
		case .off:
			"Off"
		case .near:
			"Nearby only"
		case .toward:
			"Nearby and toward"
		}
	}
}

enum DetailLev: String, CaseIterable, Identifiable {
	case minimal
	case brief
	case standard

	var id: String { rawValue }

	var label: String {
		switch self {
		case .minimal:
			"Minimal"
		case .brief:
			"Brief"
		case .standard:
			"Standard"
		}
	}
}

enum MeasurementUnit: String, CaseIterable, Identifiable {
	case feet
	case meters

	var id: String { rawValue }

	var label: String {
		switch self {
		case .feet:
			"Feet"
		case .meters:
			"Meters"
		}
	}
}

enum DirectionStyle: String, CaseIterable, Identifiable {
	case words
	case clockFace

	var id: String { rawValue }

	var label: String {
		switch self {
		case .words:
			"Words"
		case .clockFace:
			"Clock Face"
		}
	}
}

enum IntersectionWording: String, CaseIterable, Identifiable {
	case direct
	case streetContext

	var id: String { rawValue }

	var label: String {
		switch self {
		case .direct:
			"Direct"
		case .streetContext:
			"Street Context"
		}
	}
}

enum SpokenIntersectionCount: Int, CaseIterable, Identifiable {
	case one = 1
	case two = 2
	case three = 3

	var id: Int { rawValue }
	var label: String { String(rawValue) }
}
