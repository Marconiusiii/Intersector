import CoreLocation
import Foundation
import Testing
@testable import Intersector

@MainActor
struct WalkingLiveTests {
	private let start = Date(timeIntervalSince1970: 100_000)

	private func point(_ north: Double, east: Double = 0) -> CLLocationCoordinate2D {
		CLLocationCoordinate2D(latitude: 37 + north / 111_194.9266,
			longitude: -122 + east / (111_194.9266 * cos(37 * .pi / 180)))
	}

	private func sample(_ north: Double, seconds: Double, speed: Double = 1.4, accuracy: Double = 5,
		course: Double = 0, east: Double = 0) -> DeviceContext {
		DeviceContext(coordinate: point(north, east: east), headingDegrees: course,
			courseDegrees: course, courseAccuracy: 5, speedMetersPerSecond: speed,
			horizontalAccuracy: accuracy, measuredAt: start.addingTimeInterval(seconds),
			speedAccuracyMetersPerSecond: 0.2)
	}

	private func junction(_ id: String, at meters: Double, names: [String]? = nil) -> IntersectionCandidate {
		IntersectionCandidate(id: id, names: names ?? ["Oak Street", "\(id) Street"], coordinate: point(meters))
	}

	private func map(_ intersections: [IntersectionCandidate]? = nil) -> MapDataSet {
		MapDataSet(intersections: intersections ?? [junction("First", at: 100), junction("Second", at: 140), junction("Third", at: 200)],
			roads: [MapRoad(id: "oak", name: "Oak Street", nodeIDs: [1, 2], coordinates: [point(-200), point(500)])])
	}

	private func evaluate(_ tracker: inout WalkingLiveTracker, _ context: DeviceContext,
		map data: MapDataSet, count: Int = 1, road: String = "Oak Street") -> [IntersectionCandidate]? {
		let now = context.measuredAt!
		tracker.recordLocation(context, at: now)
		return tracker.intersectionsToAnnounce(from: context, in: data, on: road, count: count, at: now)
	}

	@Test(arguments: [0.5, 1.4, 2.2])
	func walkingSequencesAnnounceOnlyInsideTheSpeedAdjustedWindow(speed: Double) throws {
		var tracker = WalkingLiveTracker()
		let data = map()
		var announcements: [Double] = []
		for meters in stride(from: 0.0, through: 96.0, by: 8) {
			let context = sample(meters, seconds: meters / speed, speed: speed)
			if let candidates = evaluate(&tracker, context, map: data) {
				announcements.append(100 - meters)
				tracker.didAnnounce(candidates, in: data, on: "Oak Street", at: context.measuredAt!)
			}
		}
		let distance = try #require(announcements.first)
		let target = min(30.0, max(12.0, speed * 15))
		#expect(announcements.count == 1)
		// The idealized meter offsets can differ from the projected route by rounding.
		#expect(distance <= target + 0.001 && distance >= target - 8 - 0.001)
	}

	@Test func uncertainStaleMissingAndReplayedReadingsCannotTriggerWalking() {
		for accuracy in [20.1, 50, 100, -1, Double.nan, .infinity] {
			#expect(!WalkingLiveTracker.accepts(sample(80, seconds: 0, accuracy: accuracy), at: start))
		}
		#expect(WalkingLiveTracker.accepts(sample(80, seconds: 0, accuracy: 20), at: start))
		#expect(!WalkingLiveTracker.accepts(sample(80, seconds: -11), at: start))
		#expect(!WalkingLiveTracker.accepts(sample(80, seconds: 2), at: start))
		var missing = sample(80, seconds: 0)
		missing.measuredAt = nil
		#expect(!WalkingLiveTracker.accepts(missing, at: start))
		var tracker = WalkingLiveTracker()
		let accepted = tracker.recordLocation(sample(80, seconds: 0), at: start)
		let replayed = tracker.recordLocation(sample(81, seconds: 0), at: start)
		#expect(accepted && !replayed)
	}

	@Test func speedNoiseIsSmoothedAndInvalidSpeedUsesTheBoundedFallback() {
		var tracker = WalkingLiveTracker()
		for (index, speed) in [1.4, 1.4, 1.4, 3.0, 1.4].enumerated() {
			let context = sample(Double(index) * 5, seconds: Double(index) * 4, speed: speed)
			tracker.recordLocation(context, at: context.measuredAt!)
		}
		#expect(abs(tracker.approachDistance - 21) < 0.001)
		var invalid = sample(60, seconds: 40, speed: 20)
		invalid.speedAccuracyMetersPerSecond = -1
		tracker.recordLocation(invalid, at: invalid.measuredAt!)
		#expect(tracker.approachDistance == 20)
		invalid.measuredAt = start.addingTimeInterval(45)
		invalid.speedMetersPerSecond = 2
		invalid.speedAccuracyMetersPerSecond = 5
		tracker.recordLocation(invalid, at: invalid.measuredAt!)
		#expect(tracker.approachDistance == 20)
	}

	@Test func nextIntersectionWaitsForTwoProgressingReadingsBeyondTheFirst() throws {
		var tracker = WalkingLiveTracker()
		let data = map()
		let first = try #require(evaluate(&tracker, sample(80, seconds: 0, accuracy: 20), map: data))
		tracker.didAnnounce(first, in: data, on: "Oak Street", at: start)
		for (index, meters) in [98.0, 102, 120, 122, 128].enumerated() {
			// The next intersection is already in range at 120 m. One clear fix,
			// or two fixes only two meters apart, must not release the first junction.
			let next = evaluate(&tracker, sample(meters, seconds: Double(index + 1) * 6, accuracy: 20), map: data)
			if meters == 128 {
				#expect(next?.first?.id == "Second")
			} else { #expect(next == nil) }
		}
	}

	@Test func waitingAndDriftDoNotRepeatOrReleaseTheCurrentJunction() throws {
		var tracker = WalkingLiveTracker()
		let data = map()
		let first = try #require(evaluate(&tracker, sample(80, seconds: 0), map: data))
		tracker.didAnnounce(first, in: data, on: "Oak Street", at: start)
		for (index, meters) in [98.0, 102, 118, 101, 119, 102, 99].enumerated() {
			let result = evaluate(&tracker, sample(meters, seconds: Double(index + 1) * 100), map: data)
			#expect(result == nil)
		}
	}

	@Test func splitNodesAndStaggeredNamesShareTheWholeJunction() throws {
		for splitNames in [["Oak Street", "First Street"], ["Oak Street", "Other Street"]] {
			var tracker = WalkingLiveTracker()
			let data = map([junction("First", at: 100), junction("split", at: 112, names: splitNames), junction("Second", at: 160)])
			let first = try #require(evaluate(&tracker, sample(80, seconds: 0), map: data))
			tracker.didAnnounce(first, in: data, on: "Oak Street", at: start)
			for (index, meters) in [104.0, 116, 126, 134].enumerated() {
				#expect(evaluate(&tracker, sample(meters, seconds: Double(index + 1) * 6), map: data) == nil)
			}
			let second = evaluate(&tracker, sample(140, seconds: 30), map: data)
			#expect(second?.first?.id == "Second")
		}
	}

	@Test func previewedIntersectionsAreNotRepeatedWhenTheyBecomePrimary() throws {
		var tracker = WalkingLiveTracker()
		let data = map()
		let preview = try #require(evaluate(&tracker, sample(80, seconds: 0), map: data, count: 2))
		#expect(preview.map(\.id) == ["First", "Second"])
		tracker.didAnnounce(preview, in: data, on: "Oak Street", at: start)
		for (index, meters) in [114.0, 122, 130, 138, 146, 154, 162, 170].enumerated() {
			#expect(evaluate(&tracker, sample(meters, seconds: Double(index + 1) * 6), map: data, count: 2) == nil)
		}
		let next = evaluate(&tracker, sample(180, seconds: 60), map: data, count: 2)
		#expect(next?.map(\.id) == ["Third"])
	}

	@Test func reportNotDeliveredIsNotRecordedAsSpoken() throws {
		var tracker = WalkingLiveTracker()
		let data = map()
		#expect(evaluate(&tracker, sample(80, seconds: 0), map: data) != nil)
		// Simulate a superseded or failed formatting operation: no didAnnounce call.
		let retry = evaluate(&tracker, sample(86, seconds: 5), map: data)
		#expect(retry?.first?.id == "First")
	}

	@Test func turningAtTheJunctionReleasesItOnTheNewRoad() throws {
		var tracker = WalkingLiveTracker()
		var data = map([junction("First", at: 100)])
		data.roads.append(MapRoad(id: "first", name: "First Street", nodeIDs: [3, 4],
			coordinates: [point(100, east: -200), point(100, east: 300)]))
		data.intersections.append(IntersectionCandidate(id: "turned", names: ["First Street", "Pine Street"], coordinate: point(100, east: 45)))
		let first = try #require(evaluate(&tracker, sample(80, seconds: 0), map: data))
		tracker.didAnnounce(first, in: data, on: "Oak Street", at: start)
		#expect(evaluate(&tracker, sample(100, seconds: 20, course: 90, east: 5), map: data, road: "First Street") == nil)
		#expect(evaluate(&tracker, sample(100, seconds: 28, course: 90, east: 15), map: data, road: "First Street") == nil)
		let afterTurn = evaluate(&tracker, sample(100, seconds: 36, course: 90, east: 25), map: data, road: "First Street")
		#expect(afterTurn?.first?.id == "turned")
	}

	@Test func curvedRoadUsesRouteDistanceInsteadOfTheStraightLineShortcut() {
		var tracker = WalkingLiveTracker()
		let target = IntersectionCandidate(id: "curved", names: ["Oak Street", "First Street"], coordinate: point(0, east: 20))
		let data = MapDataSet(intersections: [target], roads: [MapRoad(id: "curve", name: "Oak Street", nodeIDs: [1, 2, 3, 4],
			coordinates: [point(0), point(40), point(40, east: 20), point(0, east: 20)])])
		#expect(Geo.distanceMeters(from: point(0), to: target.coordinate) < 21)
		#expect(evaluate(&tracker, sample(0, seconds: 0), map: data) == nil)
		#expect(evaluate(&tracker, sample(20, seconds: 20, course: 180, east: 20), map: data)?.first?.id == "curved")
	}

	@Test func leavingAnApproachByAnotherRoadDoesNotBlockLaterAnnouncements() throws {
		var tracker = WalkingLiveTracker()
		var data = map([junction("First", at: 100)])
		data.roads.append(MapRoad(id: "pine", name: "Pine Street", nodeIDs: [3, 4],
			coordinates: [point(60, east: -100), point(60, east: 200)]))
		data.intersections.append(IntersectionCandidate(id: "pine-next", names: ["Pine Street", "Elm Street"], coordinate: point(60, east: 100)))
		let first = try #require(evaluate(&tracker, sample(80, seconds: 0), map: data))
		tracker.didAnnounce(first, in: data, on: "Oak Street", at: start)
		for (index, east) in [10.0, 50, 60].enumerated() {
			let result = evaluate(&tracker, sample(60, seconds: Double(index + 1) * 20, course: 90, east: east), map: data, road: "Pine Street")
			#expect(result == nil)
		}
		let next = evaluate(&tracker, sample(60, seconds: 80, course: 90, east: 80), map: data, road: "Pine Street")
		#expect(next?.first?.id == "pine-next")
	}
}

@MainActor
private final class WalkingClock {
	var date = Date(timeIntervalSince1970: 100_000)
}

@MainActor
private final class WalkingLocationFeed: LiveLocationProviding {
	var continuation: AsyncThrowingStream<DeviceContext, Error>.Continuation?
	func updates(for mode: LiveTravelMode) async throws -> AsyncThrowingStream<DeviceContext, Error> {
		LiveLocationProvider.newestUpdateStream { self.continuation = $0 }
	}
	func updateMode(_ mode: LiveTravelMode) {}
	func stop() { continuation?.finish(); continuation = nil }
}

@MainActor
private final class WalkingSpeechRecorder: LiveSpeaking {
	var isSpeaking = false
	var messages: [String] = []
	func speak(_ text: String, settings: LiveSpeechSettings, delay: TimeInterval) { messages.append(text) }
	func stop() { isSpeaking = false }
}

@MainActor
private final class WalkingMapDownload: MapDataFetching {
	var data: MapDataSet
	var requests = 0
	var suspend = false
	var continuation: CheckedContinuation<MapDataSet, Error>?
	init(_ data: MapDataSet) { self.data = data }
	@MainActor
	func intersections(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance,
		options: MapDetailOptions) async throws -> [IntersectionCandidate] { data.intersections }
	@MainActor
	func mapData(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance,
		options: MapDetailOptions) async throws -> MapDataSet {
		requests += 1
		if suspend { return try await withCheckedThrowingContinuation { continuation = $0 } }
		return data
	}
}

extension WalkingLiveTests {
	private func settle() async {
		for _ in 0..<30 { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(10))
	}

	private func coordinator(_ clock: WalkingClock, _ locations: WalkingLocationFeed,
		_ download: WalkingMapDownload, _ speech: WalkingSpeechRecorder) -> LiveModeCoordinator {
		let service = OrientSvc(locationProvider: FakeLocationProvider(context: sample(0, seconds: 0)),
			mapDataClient: download, neighborhoodProvider: FailingNeighborhoodProvider())
		return LiveModeCoordinator(locationProvider: locations, mapDataClient: download,
			reportService: service, speechController: speech, now: { clock.date }, playsFeedback: false)
	}

	private func begin(_ live: LiveModeCoordinator, count: SpokenIntersectionCount = .one) async {
		var prefs = AppPrefs()
		prefs.areaMode = .off
		prefs.spokenIntersectionCount = count
		live.start(mode: .walking, prefs: prefs,
			speechSettings: LiveSpeechSettings(voiceIdentifier: "", ratePercent: 50, volume: 1), stationaryMinutes: 10)
		await settle()
	}

	private func send(_ context: DeviceContext, clock: WalkingClock, locations: WalkingLocationFeed) async {
		clock.date = context.measuredAt!
		locations.continuation?.yield(context)
		await settle()
	}

	@Test(arguments: [0.5, 1.4, 2.2])
	func coordinatorFollowsWalkingPaceThroughTheRoadMatcher(speed: Double) async {
		let clock = WalkingClock(), locations = WalkingLocationFeed(), speech = WalkingSpeechRecorder()
		let download = WalkingMapDownload(map())
		let live = coordinator(clock, locations, download, speech)
		await begin(live)
		defer { live.stop() }
		let target = min(30.0, max(12.0, speed * 15))
		for meters in stride(from: 0.0, through: 96.0, by: 8) {
			await send(sample(meters, seconds: meters / speed, speed: speed), clock: clock, locations: locations)
			if 100 - meters > target + 0.001 { #expect(speech.messages.count == 1) }
		}
		#expect(speech.messages.count == 2)
		#expect(speech.messages.last?.contains("First Street") == true)
		#expect(download.requests == 1)
	}

	@Test func restartingWalkingAllowsTheSameApproachInTheNewSession() async {
		let clock = WalkingClock(), locations = WalkingLocationFeed(), speech = WalkingSpeechRecorder()
		let download = WalkingMapDownload(map())
		let live = coordinator(clock, locations, download, speech)
		await begin(live)
		await send(sample(80, seconds: 0), clock: clock, locations: locations)
		live.stop()
		await begin(live)
		defer { live.stop() }
		await send(sample(82, seconds: 5), clock: clock, locations: locations)
		#expect(speech.messages.filter { $0.contains("First Street") }.count == 2)
	}

	@Test func coordinatorWaitsForSpeechAndDoesNotConsumeThePendingIntersection() async {
		let clock = WalkingClock(), locations = WalkingLocationFeed(), speech = WalkingSpeechRecorder()
		let download = WalkingMapDownload(map())
		let live = coordinator(clock, locations, download, speech)
		await begin(live)
		defer { live.stop() }
		speech.isSpeaking = true
		await send(sample(80, seconds: 0), clock: clock, locations: locations)
		#expect(speech.messages.count == 1)
		speech.isSpeaking = false
		await send(sample(88, seconds: 6), clock: clock, locations: locations)
		#expect(speech.messages.count == 2)
		#expect(speech.messages.last?.contains("First Street") == true)
		#expect(download.requests == 1)
	}

	@Test func delayedDownloadUsesTheNewPositionAndNeverSpeaksThePassedJunction() async throws {
		let clock = WalkingClock(), locations = WalkingLocationFeed(), speech = WalkingSpeechRecorder()
		let download = WalkingMapDownload(map())
		download.suspend = true
		let live = coordinator(clock, locations, download, speech)
		await begin(live)
		defer { live.stop() }
		await send(sample(80, seconds: 0), clock: clock, locations: locations)
		let completion = try #require(download.continuation)
		await send(sample(132, seconds: 40), clock: clock, locations: locations)
		completion.resume(returning: download.data)
		download.continuation = nil
		await settle()
		#expect(speech.messages.count == 2)
		#expect(speech.messages.last?.contains("Second Street") == true)
		#expect(speech.messages.last?.contains("First Street") == false)
		#expect(download.requests == 1)
	}

	@Test func downloadCompletionWithoutAFreshLocationWaitsForANewFix() async throws {
		let clock = WalkingClock(), locations = WalkingLocationFeed(), speech = WalkingSpeechRecorder()
		let download = WalkingMapDownload(map())
		download.suspend = true
		let live = coordinator(clock, locations, download, speech)
		await begin(live)
		defer { live.stop() }
		await send(sample(80, seconds: 0), clock: clock, locations: locations)
		let completion = try #require(download.continuation)
		clock.date = start.addingTimeInterval(15)
		completion.resume(returning: download.data)
		download.continuation = nil
		await settle()
		#expect(speech.messages.count == 1)
		await send(sample(86, seconds: 20), clock: clock, locations: locations)
		#expect(speech.messages.count == 2)
		#expect(speech.messages.last?.contains("First Street") == true)
	}

	@Test func coordinatorRejectsImpreciseLocationsAndRemembersEveryFormattedIntersection() async {
		let clock = WalkingClock(), locations = WalkingLocationFeed(), speech = WalkingSpeechRecorder()
		let download = WalkingMapDownload(map([junction("First", at: 100), junction("Second", at: 160),
			junction("Third", at: 230), junction("Fourth", at: 300)]))
		let live = coordinator(clock, locations, download, speech)
		await begin(live, count: .two)
		defer { live.stop() }
		await send(sample(80, seconds: 0, accuracy: 100), clock: clock, locations: locations)
		#expect(download.requests == 0)
		#expect(speech.messages.count == 1)
		for (index, meters) in [80.0, 114, 122, 140, 170, 174, 182, 210].enumerated() {
			await send(sample(meters, seconds: Double(index + 1) * 10), clock: clock, locations: locations)
		}
		#expect(speech.messages.count == 3)
		#expect(speech.messages.filter { $0.contains("Second Street") }.count == 1)
		#expect(speech.messages.last?.contains("Third Street") == true)
		#expect(speech.messages.last?.contains("Fourth Street") == true)
		#expect(download.requests == 1)
	}
}
