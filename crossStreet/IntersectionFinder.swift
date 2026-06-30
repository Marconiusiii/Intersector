//
//  IntersectionFinder.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Foundation

struct IntersectionFinder {
	static let upcomingConeDegrees: CLLocationDirection = 35
	static let scanMaxDistanceMeters: CLLocationDistance = 600 / 3.28084

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
			if kind == .scan {
				return scanMatch(from: context, in: candidates)?.candidate
			}
			return candidates.reduce(nil) { best, candidate in
				let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				guard angleDelta(from: heading, to: bearing) <= Self.upcomingConeDegrees else {
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

	func rankedUpcoming(
		from context: DeviceContext,
		in candidates: [IntersectionCandidate]
	) -> [IntersectionCandidate] {
		guard let heading = context.headingDegrees else {
			return []
		}
		let forwardCandidates = candidates.filter { candidate in
			let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
			return angleDelta(from: heading, to: bearing) <= Self.upcomingConeDegrees
		}
		return rankedNearest(from: context.coordinate, in: forwardCandidates)
	}

	func rankedUpcoming(
		from context: DeviceContext,
		in mapData: MapDataSet
	) -> [IntersectionCandidate] {
		mapData.rankedUpcoming(from: context) ?? rankedUpcoming(
			from: context,
			in: mapData.intersections
		)
	}

	func upcoming(
		rank: Int,
		from context: DeviceContext,
		in candidates: [IntersectionCandidate]
	) -> IntersectionCandidate? {
		guard rank > 0 else {
			return nil
		}
		let ranked = rankedUpcoming(from: context, in: candidates)
		guard ranked.indices.contains(rank - 1) else {
			return nil
		}
		return ranked[rank - 1]
	}

	func upcoming(
		rank: Int,
		from context: DeviceContext,
		in mapData: MapDataSet
	) -> IntersectionCandidate? {
		guard rank > 0 else {
			return nil
		}
		let ranked = rankedUpcoming(from: context, in: mapData)
		guard ranked.indices.contains(rank - 1) else {
			return nil
		}
		return ranked[rank - 1]
	}

	func scanMatch(
		from context: DeviceContext,
		in candidates: [IntersectionCandidate],
		maxDistanceMeters: CLLocationDistance = Self.scanMaxDistanceMeters
	) -> ScanMatch? {
		guard let heading = context.headingDegrees else {
			return nil
		}

		return candidates
			.compactMap { candidate -> ScanMatch? in
				let distance = Geo.distanceMeters(from: context.coordinate, to: candidate.coordinate)
				guard distance <= maxDistanceMeters else {
					return nil
				}
				let bearing = Geo.bearingDegrees(from: context.coordinate, to: candidate.coordinate)
				let delta = angleDelta(from: heading, to: bearing)
				return ScanMatch(
					candidate: candidate,
					distanceMeters: distance,
					bearingDegrees: bearing,
					angleDelta: delta
				)
			}
			.reduce(nil) { best, candidate in
				guard let best else {
					return candidate
				}
				if abs(candidate.angleDelta - best.angleDelta) > 5 {
					return candidate.angleDelta < best.angleDelta ? candidate : best
				}
				return candidate.distanceMeters < best.distanceMeters ? candidate : best
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
