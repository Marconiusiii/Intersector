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
			return rankedNearest(from: context.coordinate, in: candidates).first
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

	func nearest(
		rank: Int,
		from coordinate: CLLocationCoordinate2D,
		in candidates: [IntersectionCandidate]
	) -> IntersectionCandidate? {
		guard rank > 0 else {
			return nil
		}
		let ranked = rankedNearest(from: coordinate, in: candidates)
		guard ranked.indices.contains(rank - 1) else {
			return nil
		}
		return ranked[rank - 1]
	}

	func rankedNearest(
		from coordinate: CLLocationCoordinate2D,
		in candidates: [IntersectionCandidate]
	) -> [IntersectionCandidate] {
		let sorted = candidates.sorted {
			Geo.distanceMeters(from: coordinate, to: $0.coordinate)
				< Geo.distanceMeters(from: coordinate, to: $1.coordinate)
		}

		return sorted.reduce(into: []) { unique, candidate in
			let isDuplicate = unique.contains { existing in
				normalizedNames(existing.names) == normalizedNames(candidate.names) &&
					Geo.distanceMeters(from: existing.coordinate, to: candidate.coordinate) < 30
			}
			if !isDuplicate {
				unique.append(candidate)
			}
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

	private func normalizedNames(_ names: [String]) -> Set<String> {
		Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
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
