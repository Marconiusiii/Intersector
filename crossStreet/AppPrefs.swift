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
	var mapDetails = MapDetailOptions()
	var haptics = true

	nonisolated init(
		areaMode: AreaMode = .near,
		detail: DetailLev = .standard,
		measurementUnit: MeasurementUnit = .feet,
		directionStyle: DirectionStyle = .words,
		mapDetails: MapDetailOptions = MapDetailOptions(),
		haptics: Bool = true
	) {
		self.areaMode = areaMode
		self.detail = detail
		self.measurementUnit = measurementUnit
		self.directionStyle = directionStyle
		self.mapDetails = mapDetails
		self.haptics = haptics
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
	case brief
	case standard

	var id: String { rawValue }

	var label: String {
		switch self {
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
