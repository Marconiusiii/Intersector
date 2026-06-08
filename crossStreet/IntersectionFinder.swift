//
//  IntersectionFinder.swift
//  crossStreet
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Foundation

struct IntersectionFinder {
	func bestMatch(
		for kind: ReportKind,
		from context: DeviceContext,
		in candidates: [IntersectionCandidate]
	) -> IntersectionCandidate? {
		let sorted = candidates.sorted {
			Geo.distanceMeters(from: context.coordinate, to: $0.coordinate)
				< Geo.distanceMeters(from: context.coordinate, to: $1.coordinate)
		}

		switch kind {
		case .nearest:
			return sorted.first
		case .upcoming, .scan:
			guard let heading = context.headingDegrees else {
				return sorted.first
			}
			return sorted.first { candidate in
				let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				let delta = abs(Geo.normalizedDegrees(bearing - heading))
				let smallestDelta = min(delta, 360 - delta)
				return smallestDelta <= 60
			} ?? sorted.first
		}
	}

	func scanMatch(
		from context: DeviceContext,
		in candidates: [IntersectionCandidate]
	) -> ScanMatch? {
		guard let heading = context.headingDegrees else {
			return nil
		}

		return candidates
			.map { candidate in
				let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				let distance = Geo.distanceMeters(from: context.coordinate, to: candidate.coordinate)
				let delta = angleDelta(from: heading, to: bearing)
				return ScanMatch(
					candidate: candidate,
					distanceMeters: distance,
					bearingDegrees: bearing,
					angleDelta: delta
				)
			}
			.sorted {
				if abs($0.angleDelta - $1.angleDelta) > 5 {
					return $0.angleDelta < $1.angleDelta
				}
				return $0.distanceMeters < $1.distanceMeters
			}
			.first
	}

	func angleDelta(
		from heading: CLLocationDirection,
		to bearing: CLLocationDirection
	) -> CLLocationDirection {
		let delta = abs(Geo.normalizedDegrees(bearing - heading))
		return min(delta, 360 - delta)
	}
}

struct ScanMatch: Equatable {
	var candidate: IntersectionCandidate
	var distanceMeters: CLLocationDistance
	var bearingDegrees: CLLocationDirection
	var angleDelta: CLLocationDirection
}
