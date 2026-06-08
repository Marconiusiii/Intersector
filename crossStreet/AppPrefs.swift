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
	var haptics = true

	nonisolated init(
		areaMode: AreaMode = .near,
		detail: DetailLev = .standard,
		haptics: Bool = true
	) {
		self.areaMode = areaMode
		self.detail = detail
		self.haptics = haptics
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
