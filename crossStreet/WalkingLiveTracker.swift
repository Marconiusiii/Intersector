import CoreLocation
import Foundation

/// Walking owns its approach and passage state separately from Driving's distance gate.
struct WalkingLiveTracker {
	private struct SpeedReading {
		var metersPerSecond: Double
		var date: Date
	}

	private struct Junction {
		var members: [IntersectionCandidate]

		func contains(_ candidate: IntersectionCandidate) -> Bool {
			members.contains { member in
				if member.id == candidate.id { return true }
				let sameKind = member.id.hasPrefix("crossing-") == candidate.id.hasPrefix("crossing-")
				let names = Set(member.names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
				let otherNames = Set(candidate.names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
				return sameKind && names == otherNames &&
					Geo.distanceMeters(from: member.coordinate, to: candidate.coordinate) <= 30
			}
		}
	}

	private struct Departure {
		var date: Date
		var distance: Double
		var road: String
	}

	private struct Encounter {
		var junction: Junction
		var wasSpoken: Bool
		var departure: Departure?
	}

	private struct Spoken {
		var junction: Junction
		var date: Date
	}

	private var speeds: [SpeedReading] = []
	private var lastRecordedAt: Date?
	private var lastEvaluatedAt: Date?
	private var encounter: Encounter?
	private var spoken: [Spoken] = []

	var approachDistance: CLLocationDistance {
		let ordered = speeds.map(\.metersPerSecond).sorted()
		guard !ordered.isEmpty else { return 20 }
		let middle = ordered.count / 2
		let median = ordered.count.isMultiple(of: 2)
			? (ordered[middle - 1] + ordered[middle]) / 2
			: ordered[middle]
		return min(30, max(12, median * 15))
	}

	static func accepts(_ context: DeviceContext, at now: Date) -> Bool {
		guard CLLocationCoordinate2DIsValid(context.coordinate),
			let accuracy = context.horizontalAccuracy, accuracy.isFinite, accuracy >= 0, accuracy <= 20,
			let measuredAt = context.measuredAt else { return false }
		let age = now.timeIntervalSince(measuredAt)
		return age >= -1 && age <= 10
	}

	/// Use the source timestamp so replayed fixes cannot influence the speed estimate.
	@discardableResult
	mutating func recordLocation(_ context: DeviceContext, at now: Date) -> Bool {
		guard Self.accepts(context, at: now), let date = context.measuredAt,
			lastRecordedAt.map({ date > $0 }) ?? true else { return false }
		lastRecordedAt = date
		speeds.removeAll { date.timeIntervalSince($0.date) > 20 }
		guard let speed = context.speedMetersPerSecond, speed.isFinite, speed >= 0, speed <= 3,
			let uncertainty = context.speedAccuracyMetersPerSecond,
			uncertainty.isFinite, uncertainty >= 0, uncertainty <= 0.75 else { return true }
		speeds.append(SpeedReading(metersPerSecond: speed, date: date))
		if speeds.count > 5 { speeds.removeFirst(speeds.count - 5) }
		return true
	}

	/// Returns the intersections eligible for one report. Speech is recorded only after
	/// formatting succeeds and the coordinator verifies the location is still current.
	mutating func intersectionsToAnnounce(
		from context: DeviceContext,
		in map: MapDataSet,
		on roadName: String,
		count: Int,
		at now: Date
	) -> [IntersectionCandidate]? {
		guard count > 0, Self.accepts(context, at: now), let date = context.measuredAt,
			let heading = context.headingDegrees, heading.isFinite,
			lastEvaluatedAt.map({ date > $0 }) ?? true else { return nil }
		lastEvaluatedAt = date
		spoken.removeAll { now.timeIntervalSince($0.date) >= 600 }
		let ahead = map.positionsAlongUpcomingRoad(from: context, preferredRoadName: roadName) ?? []
		updateEncounter(from: context, map: map, roadName: roadName, ahead: ahead, date: date)
		guard let first = ahead.first, first.metersAhead <= approachDistance else { return nil }

		if encounter == nil {
			encounter = Encounter(
				junction: junction(for: first.intersection, in: map, on: roadName),
				wasSpoken: hasSpoken(first.intersection)
			)
		}
		guard let encounter, !encounter.wasSpoken,
			encounter.junction.contains(first.intersection) else { return nil }

		var selected: [IntersectionCandidate] = []
		var selectedJunctions: [Junction] = []
		for position in ahead where !hasSpoken(position.intersection) {
			let candidate = position.intersection
			if !selectedJunctions.contains(where: { $0.contains(candidate) }) {
				selected.append(candidate)
				selectedJunctions.append(junction(for: candidate, in: map, on: roadName))
			}
			if selected.count == count { break }
		}
		return selected.isEmpty ? nil : selected
	}

	mutating func didAnnounce(_ intersections: [IntersectionCandidate], in map: MapDataSet, on roadName: String, at now: Date) {
		guard let first = intersections.first,
			encounter?.junction.contains(first) == true else { return }
		encounter?.wasSpoken = true
		for intersection in intersections where !hasSpoken(intersection) {
			spoken.append(Spoken(junction: junction(for: intersection, in: map, on: roadName), date: now))
		}
	}

	private func hasSpoken(_ candidate: IntersectionCandidate) -> Bool {
		spoken.contains { $0.junction.contains(candidate) }
	}

	private func junction(for candidate: IntersectionCandidate, in map: MapDataSet, on roadName: String) -> Junction {
		let seed = Junction(members: [candidate])
		let crossStreets = Set(map.crossStreetNames(for: candidate, on: roadName, heading: nil))
		let members = map.intersections.filter { other in
			guard other.id != candidate.id else { return false }
			if seed.contains(other) { return true }
			// Match the formatter's existing treatment of staggered junctions so every
			// node named by a single report shares that report's passage and repeat state.
			guard !candidate.id.hasPrefix("crossing-"), !other.id.hasPrefix("crossing-"),
				other.roadNames.contains(roadName), !crossStreets.isEmpty,
				Geo.distanceMeters(from: candidate.coordinate, to: other.coordinate) <= 30 else { return false }
			return Set(map.crossStreetNames(for: other, on: roadName, heading: nil)) == crossStreets
		}
		return Junction(members: [candidate] + members)
	}

	private mutating func updateEncounter(
		from context: DeviceContext, map: MapDataSet, roadName: String,
		ahead: [UpcomingRoadPosition], date: Date
	) {
		guard var current = encounter else { return }
		// A mapped node disappearing from Upcoming is not proof that the crossing is over.
		// Verify the whole junction on the reverse route, including a turn onto its other street.
		var reverse = context
		reverse.headingDegrees = Geo.normalizedDegrees((context.headingDegrees ?? 0) + 180)
		let behind = map.positionsAlongUpcomingRoad(from: reverse, preferredRoadName: roadName) ?? []
		let clearance = max(12, context.horizontalAccuracy ?? 20)
		let membersOnRoad = current.junction.members.filter { $0.roadNames.contains(roadName) }
		let distancesBehind = membersOnRoad.compactMap { member in
			behind.first(where: { $0.intersection.id == member.id })?.metersAhead
		}
		let isBehind = !membersOnRoad.isEmpty && distancesBehind.count == membersOnRoad.count &&
			distancesBehind.allSatisfy { $0 >= clearance } &&
			!ahead.contains(where: { current.junction.contains($0.intersection) })
		let distanceAway = current.junction.members.map {
			Geo.distanceMeters(from: $0.coordinate, to: context.coordinate)
		}.min() ?? 0
		// Turning away before reaching a junction must not leave Live permanently blocked.
		let departureDistance: Double? = isBehind ? distancesBehind.min() : (distanceAway >= 60 ? distanceAway : nil)
		if let distance = departureDistance {
			if let previous = current.departure, previous.road == roadName,
				date.timeIntervalSince(previous.date) >= 2, distance >= previous.distance + 4 {
				encounter = nil
				return
			}
			if current.departure == nil || current.departure?.road != roadName {
				current.departure = Departure(date: date, distance: distance, road: roadName)
			}
		} else {
			current.departure = nil
		}
		encounter = current
	}
}
