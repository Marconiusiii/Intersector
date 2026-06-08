//
//  IntersectionFinder.swift
//  Intersector
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
		switch kind {
		case .nearest:
			return nearestCandidate(from: context.coordinate, in: candidates)
		case .upcoming, .scan:
			guard let heading = context.headingDegrees else {
				return nearestCandidate(from: context.coordinate, in: candidates)
			}
			return candidates.reduce(nil) { best, candidate in
				let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				guard angleDelta(from: heading, to: bearing) <= 60 else {
					return best
				}
				return nearest(
					best,
					or: candidate,
					from: context.coordinate
				)
			} ?? nearestCandidate(from: context.coordinate, in: candidates)
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
			.reduce(nil) { best, candidate in
				let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				let distance = Geo.distanceMeters(from: context.coordinate, to: candidate.coordinate)
				let delta = angleDelta(from: heading, to: bearing)
				let match = ScanMatch(
					candidate: candidate,
					distanceMeters: distance,
					bearingDegrees: bearing,
					angleDelta: delta
				)
				guard let best else {
					return match
				}
				if abs(match.angleDelta - best.angleDelta) > 5 {
					return match.angleDelta < best.angleDelta ? match : best
				}
				return match.distanceMeters < best.distanceMeters ? match : best
			}
	}

	func angleDelta(
		from heading: CLLocationDirection,
		to bearing: CLLocationDirection
	) -> CLLocationDirection {
		let delta = abs(Geo.normalizedDegrees(bearing - heading))
		return min(delta, 360 - delta)
	}

	private func nearestCandidate(
		from coordinate: CLLocationCoordinate2D,
		in candidates: [IntersectionCandidate]
	) -> IntersectionCandidate? {
		candidates.reduce(nil) { best, candidate in
			nearest(best, or: candidate, from: coordinate)
		}
	}

	private func nearest(
		_ current: IntersectionCandidate?,
		or candidate: IntersectionCandidate,
		from coordinate: CLLocationCoordinate2D
	) -> IntersectionCandidate {
		guard let current else {
			return candidate
		}
		let currentDistance = Geo.distanceMeters(from: coordinate, to: current.coordinate)
		let candidateDistance = Geo.distanceMeters(from: coordinate, to: candidate.coordinate)
		return candidateDistance < currentDistance ? candidate : current
	}
}

struct ScanMatch: Equatable {
	var candidate: IntersectionCandidate
	var distanceMeters: CLLocationDistance
	var bearingDegrees: CLLocationDirection
	var angleDelta: CLLocationDirection
}
