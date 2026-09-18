import AVFoundation
import CoreLocation
import Foundation
import Testing
@testable import Intersector

@MainActor
struct LiveModeTests {
	@Test func liveModeAvailabilityPreservesExistingAccessAndHonorsSavedSwitch() throws {
		let suiteName = "LiveModeTests.availability.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		#expect(LiveModeAvailability.isEnabled(in: defaults))
		defaults.set(false, forKey: LiveModeAvailability.enabledKey)
		#expect(!LiveModeAvailability.isEnabled(in: defaults))
		defaults.set(true, forKey: LiveModeAvailability.enabledKey)
		#expect(LiveModeAvailability.isEnabled(in: defaults))
	}

	@Test func speechRatePercentageMapsAcrossTheSystemSpeechRange() {
		#expect(SystemSpeechController.speechRate(forPercent: 0) == AVSpeechUtteranceMinimumSpeechRate)
		#expect(SystemSpeechController.speechRate(forPercent: 100) == AVSpeechUtteranceMaximumSpeechRate)
		#expect(SystemSpeechController.speechRate(forPercent: -10) == AVSpeechUtteranceMinimumSpeechRate)
		#expect(SystemSpeechController.speechRate(forPercent: 110) == AVSpeechUtteranceMaximumSpeechRate)
	}

	@Test func newestLocationBufferDiscardsSupersededUpdates() async throws {
		var continuation: AsyncThrowingStream<DeviceContext, Error>.Continuation?
		let stream = LiveLocationProvider.newestUpdateStream { continuation = $0 }
		continuation?.yield(
			DeviceContext(
				coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
				headingDegrees: nil
			)
		)
		continuation?.yield(
			DeviceContext(
				coordinate: CLLocationCoordinate2D(latitude: 38, longitude: -121),
				headingDegrees: nil
			)
		)
		continuation?.finish()

		var received: [DeviceContext] = []
		for try await context in stream {
			received.append(context)
		}

		#expect(received.count == 1)
		#expect(received.first?.coordinate.latitude == 38)
		#expect(received.first?.coordinate.longitude == -121)
	}

	@Test func supersededSpeechCallbackCannotFinishTheCurrentUtterance() {
		let first = AVSpeechUtterance(string: "First")
		let second = AVSpeechUtterance(string: "Second")
		var tracker = SpeechUtteranceTracker()

		tracker.begin(first)
		tracker.begin(second)
		let olderCallbackFinished = tracker.finishIfCurrent(first)

		#expect(!olderCallbackFinished)
		#expect(tracker.currentID == ObjectIdentifier(second))
		let currentCallbackFinished = tracker.finishIfCurrent(second)
		#expect(currentCallbackFinished)
		#expect(tracker.currentID == nil)
	}

	@Test func systemVoicesMatchTheDeviceLanguageCode() {
		#expect(LiveSpeechVoice.matchesDeviceLanguage(voiceLanguage: "en-US", deviceLanguageCode: "en"))
		#expect(LiveSpeechVoice.matchesDeviceLanguage(voiceLanguage: "en-GB", deviceLanguageCode: "en-US"))
		#expect(!LiveSpeechVoice.matchesDeviceLanguage(voiceLanguage: "es-MX", deviceLanguageCode: "en-US"))
	}

	@Test func liveModeLifecycleFeedbackUsesClearStateMessagesAndDistinctToneDirections() {
		#expect(LiveModeCoordinator.activationMessage(for: .walking) == "Live Mode on. Walking.")
		#expect(LiveModeCoordinator.activationMessage(for: .driving) == "Live Mode on. Driving.")
		#expect(LiveModeEarcon.frequencies(isActive: true) == [494, 660, 988])
		#expect(LiveModeEarcon.frequencies(isActive: false) == [988, 660, 494])
	}

	@Test func liveModeShortcutCommandsHaveDeterministicStatesAndResults() {
		#expect(LiveModeShortcutCommand(rawValue: "start") == .start)
		#expect(LiveModeShortcutCommand(rawValue: "stop") == .stop)
		#expect(LiveModeShortcutCommand.start.resultDialog == "Opening Intersector to start Live Mode.")
		#expect(LiveModeShortcutCommand.stop.resultDialog == "Opening Intersector to stop Live Mode.")
	}

	@Test func liveUpcomingUsesTheExistingUpcomingFormatter() async throws {
		let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)
		let mapData = northboundMapData(origin: origin)
		let context = DeviceContext(
			coordinate: origin,
			headingDegrees: 0,
			courseDegrees: 0,
			courseAccuracy: 5,
			speedMetersPerSecond: 1.4,
			horizontalAccuracy: 8
		)
		let service = OrientSvc(
			locationProvider: FakeLocationProvider(context: context),
			mapDataClient: StaticMapDataClient(data: mapData),
			neighborhoodProvider: FailingNeighborhoodProvider()
		)
		var prefs = AppPrefs()
		prefs.areaMode = .off
		prefs.spokenIntersectionCount = .two
		prefs.announcementOptions = AnnouncementOptions(
			includeDistance: true,
			includeDirection: true,
			includeNeighborhood: false
		)

		let manualText = try await service.spokenText(.upcoming, prefs: prefs)
		let liveResult = try await service.liveUpcomingResult(
			from: context,
			mapData: mapData,
			prefs: prefs,
			preferredRoadName: "Oak Street"
		)

		#expect(liveResult.text == manualText)
		#expect(liveResult.primaryIntersectionID == "first")
	}

	@Test func roadMatcherUsesMovementCourseAndKeepsTheCurrentRoad() throws {
		let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)
		let parallelLongitude = -121.9998
		let mapData = MapDataSet(
			intersections: [],
			roads: [
				MapRoad(
					id: "oak",
					name: "Oak Street",
					nodeIDs: [1, 2],
					coordinates: [
						CLLocationCoordinate2D(latitude: 36.995, longitude: -122),
						CLLocationCoordinate2D(latitude: 37.005, longitude: -122)
					]
				),
				MapRoad(
					id: "pine",
					name: "Pine Street",
					nodeIDs: [3, 4],
					coordinates: [
						CLLocationCoordinate2D(latitude: 36.995, longitude: parallelLongitude),
						CLLocationCoordinate2D(latitude: 37.005, longitude: parallelLongitude)
					]
				)
			]
		)
		var matcher = LiveRoadMatcher()
		let firstValue = matcher.match(
			DeviceContext(
				coordinate: origin,
				headingDegrees: nil,
				courseDegrees: 0,
				courseAccuracy: 5,
				speedMetersPerSecond: 1.2,
				horizontalAccuracy: 8
			),
			in: mapData,
			mode: .walking
		)
		let first = try #require(firstValue)
		let noisySecondValue = matcher.match(
			DeviceContext(
				coordinate: CLLocationCoordinate2D(latitude: 37.0001, longitude: -121.99986),
				headingDegrees: nil,
				courseDegrees: 0,
				courseAccuracy: 8,
				speedMetersPerSecond: 1.2,
				horizontalAccuracy: 18
			),
			in: mapData,
			mode: .walking
		)
		let noisySecond = try #require(noisySecondValue)

		#expect(first.roadName == "Oak Street")
		#expect(noisySecond.roadName == "Oak Street")
		#expect(noisySecond.context.headingDegrees == 0)
	}

	@Test func drivingMatcherRejectsPedestrianOnlyPaths() throws {
		let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)
		let data = MapDataSet(
			intersections: [],
			roads: [
				MapRoad(
					id: "path",
					name: "Garden Path",
					nodeIDs: [1, 2],
					coordinates: [
						CLLocationCoordinate2D(latitude: 36.999, longitude: -122),
						CLLocationCoordinate2D(latitude: 37.001, longitude: -122)
					],
					highway: "footway"
				)
			]
		)
		var matcher = LiveRoadMatcher()
		let context = DeviceContext(
			coordinate: origin,
			headingDegrees: nil,
			courseDegrees: 0,
			courseAccuracy: 5,
			speedMetersPerSecond: 8,
			horizontalAccuracy: 5
		)

		let drivingMatch = matcher.match(context, in: data, mode: .driving)
		let walkingMatch = matcher.match(context, in: data, mode: .walking)

		#expect(drivingMatch == nil)
		#expect(walkingMatch?.roadName == "Garden Path")
	}

	@Test func announcementGateUsesModeDistanceAndSuppressesRepeats() {
		var gate = LiveAnnouncementGate()
		let now = Date(timeIntervalSince1970: 1_000)

		let tooFar = gate.shouldAnnounce(intersectionID: "first", distanceMeters: 100, mode: .walking, now: now)
		let firstApproach = gate.shouldAnnounce(intersectionID: "first", distanceMeters: 80, mode: .walking, now: now)
		let repeatedApproach = gate.shouldAnnounce(
			intersectionID: "first",
			distanceMeters: 40,
			mode: .walking,
			now: now.addingTimeInterval(30)
		)
		let drivingApproach = gate.shouldAnnounce(intersectionID: "second", distanceMeters: 300, mode: .driving, now: now)

		#expect(!tooFar)
		#expect(firstApproach)
		#expect(!repeatedApproach)
		#expect(drivingApproach)
	}

	@Test func stationaryMonitorUsesElapsedTimeIgnoresGpsDriftAndResetsAfterRealMovement() {
		let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)
		let start = Date(timeIntervalSince1970: 10_000)
		var monitor = LiveMovementMonitor()
		monitor.reset(at: start)
		for seconds in stride(from: 0, through: 280, by: 20) {
			monitor.record(
				DeviceContext(coordinate: CLLocationCoordinate2D(latitude: 37.00005, longitude: -122),
							  headingDegrees: nil, horizontalAccuracy: 10),
				at: start.addingTimeInterval(Double(seconds))
			)
		}

		#expect(!monitor.hasTimedOut(after: 5, at: start.addingTimeInterval(299)))
		#expect(monitor.hasTimedOut(after: 5, at: start.addingTimeInterval(301)))

		monitor.record(
			DeviceContext(
				coordinate: CLLocationCoordinate2D(latitude: 37.0004, longitude: -122),
				headingDegrees: nil,
				horizontalAccuracy: 10
			),
			at: start.addingTimeInterval(310)
		)

		#expect(!monitor.hasTimedOut(after: 5, at: start.addingTimeInterval(500)))
	}

	private func northboundMapData(origin: CLLocationCoordinate2D) -> MapDataSet {
		MapDataSet(
			intersections: [
				IntersectionCandidate(
					id: "first",
					names: ["Oak Street", "First Street"],
					coordinate: CLLocationCoordinate2D(latitude: origin.latitude + 0.0005, longitude: origin.longitude)
				),
				IntersectionCandidate(
					id: "second",
					names: ["Oak Street", "Second Street"],
					coordinate: CLLocationCoordinate2D(latitude: origin.latitude + 0.001, longitude: origin.longitude)
				)
			],
			roads: [
				MapRoad(
					id: "oak",
					name: "Oak Street",
					nodeIDs: [1, 2],
					coordinates: [
						CLLocationCoordinate2D(latitude: origin.latitude - 0.002, longitude: origin.longitude),
						CLLocationCoordinate2D(latitude: origin.latitude + 0.003, longitude: origin.longitude)
					]
				),
				MapRoad(
					id: "first-road",
					name: "First Street",
					nodeIDs: [3, 4],
					coordinates: [
						CLLocationCoordinate2D(latitude: origin.latitude + 0.0005, longitude: origin.longitude - 0.001),
						CLLocationCoordinate2D(latitude: origin.latitude + 0.0005, longitude: origin.longitude + 0.001)
					]
				),
				MapRoad(
					id: "second-road",
					name: "Second Street",
					nodeIDs: [5, 6],
					coordinates: [
						CLLocationCoordinate2D(latitude: origin.latitude + 0.001, longitude: origin.longitude - 0.001),
						CLLocationCoordinate2D(latitude: origin.latitude + 0.001, longitude: origin.longitude + 0.001)
					]
				)
			]
		)
	}
}

@MainActor
private final class LiveTestClock {
	var date = Date(timeIntervalSince1970: 50_000)
}

@MainActor
private final class LiveTestLocation: LiveLocationProviding {
	var continuation: AsyncThrowingStream<DeviceContext, Error>.Continuation?
	var starts = 0
	var stops = 0
	var mode: LiveTravelMode?
	func updates(for mode: LiveTravelMode) async throws -> AsyncThrowingStream<DeviceContext, Error> {
		self.mode = mode
		starts += 1
		return LiveLocationProvider.newestUpdateStream { self.continuation = $0 }
	}
	func updateMode(_ mode: LiveTravelMode) { self.mode = mode }
	func stop() {
		stops += 1
		continuation?.finish()
		continuation = nil
	}
}

@MainActor
private final class LiveTestSpeech: LiveSpeaking {
	var messages: [String] = []
	func speak(_ text: String, settings: LiveSpeechSettings, delay: TimeInterval) { messages.append(text) }
	func stop() {}
}

@MainActor
private final class LiveTestMap: MapDataFetching {
	var data = MapDataSet(intersections: [], roads: [])
	var requests = 0
	var options: [MapDetailOptions] = []
	var suspend = false
	var failure: Error?
	var continuation: CheckedContinuation<MapDataSet, Error>?
	@MainActor
	func intersections(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> [IntersectionCandidate] { data.intersections }
	@MainActor
	func mapData(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> MapDataSet {
		requests += 1
		self.options.append(options)
		if let failure { throw failure }
		if suspend { return try await withCheckedThrowingContinuation { continuation = $0 } }
		return data
	}
}

@MainActor
struct LiveDrivingReliabilityTests {
	private let settings = LiveSpeechSettings(voiceIdentifier: "", ratePercent: 50, volume: 1)

	private func context(_ north: Double = 0, east: Double = 0) -> DeviceContext {
		DeviceContext(coordinate: CLLocationCoordinate2D(latitude: 37 + north, longitude: -122 + east),
					  headingDegrees: nil, courseDegrees: 0, courseAccuracy: 5,
					  speedMetersPerSecond: 20, horizontalAccuracy: 5)
	}

	private func highway(_ type: String = "motorway", east: Double = 0) -> MapRoad {
		MapRoad(id: "highway", name: "Junipero Serra Freeway", nodeIDs: [1, 2],
				coordinates: [context(-0.01, east: east).coordinate, context(0.1, east: east).coordinate],
				highway: type, routeReference: "I-280", oneWay: "yes", limitedAccess: type == "motorway")
	}

	private func coordinator(_ location: LiveTestLocation, _ map: LiveTestMap, _ speech: LiveTestSpeech, _ clock: LiveTestClock) -> LiveModeCoordinator {
		let service = OrientSvc(locationProvider: FakeLocationProvider(context: context()),
								mapDataClient: map, neighborhoodProvider: FailingNeighborhoodProvider())
		return LiveModeCoordinator(locationProvider: location, mapDataClient: map,
								   reportService: service, speechController: speech,
								   now: { clock.date }, playsFeedback: false)
	}

	private func settle() async {
		for _ in 0..<30 { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(10))
	}

	@Test func highwayNeedsSustainedMainRoadMatchAndRejectsRamps() {
		let data = MapDataSet(intersections: [], roads: [highway()])
		var detector = LiveHighwayDetector()
		let start = Date()
		#expect(detector.highwayEntered(in: data, context: context(), now: start) == nil)
		#expect(detector.highwayEntered(in: data, context: context(0.0002), now: start.addingTimeInterval(2)) == nil)
		#expect(detector.highwayEntered(in: data, context: context(0.0004), now: start.addingTimeInterval(4))?.routeReference == "I-280")
		for type in ["motorway_link", "trunk_link", "trunk", "primary"] {
			detector.reset()
			let ramps = MapDataSet(intersections: [], roads: [highway(type)])
			for index in 0..<5 {
				#expect(detector.highwayEntered(in: ramps, context: context(Double(index) * 0.0002), now: start.addingTimeInterval(Double(index) * 2)) == nil)
			}
		}
	}

	@Test func parallelRoadPoorAccuracyAndOppositeDirectionDoNotShutDown() {
		var nearby = highway("residential", east: 0.00005)
		nearby.id = "frontage"
		let start = Date()
		for scenario in 0..<3 {
			var detector = LiveHighwayDetector()
			for index in 0..<5 {
				var sample = context(Double(index) * 0.0002)
				if scenario == 1 { sample.horizontalAccuracy = 70 }
				if scenario == 2 { sample.courseDegrees = 180 }
				let roads = scenario == 0 ? [highway(), nearby] : [highway()]
				#expect(detector.highwayEntered(in: MapDataSet(intersections: [], roads: roads), context: sample, now: start.addingTimeInterval(Double(index) * 2)) == nil)
			}
		}
	}

	@Test func highwayShutdownStopsLocationAndManualRestartWorks() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		map.data.roads = [highway()]
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		await settle()
		for index in 0..<3 {
			clock.date = Date(timeIntervalSince1970: 50_000 + Double(index) * 2)
			location.continuation?.yield(context(Double(index) * 0.0002))
			await settle()
		}
		#expect(!live.isActive)
		#expect(location.stops == 1)
		#expect(speech.messages.last == "Entering I-280. Live Mode off. Turn Live back on after exiting the highway.")
		#expect(map.options.first?.includeHighways == true)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		await settle()
		#expect(live.isActive)
		#expect(location.starts == 2)
		live.stop()
	}

	@Test func modeSwitchDoesNotRestartLocationAndWalkingDoesNotShutDownOnHighway() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		map.data.roads = [highway()]
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		live.switchMode(to: .walking)
		await settle()
		#expect(location.mode == .walking)
		for index in 0..<4 {
			clock.date = clock.date.addingTimeInterval(2)
			location.continuation?.yield(context(Double(index) * 0.0002))
			await settle()
		}
		live.switchMode(to: .driving)
		live.switchMode(to: .driving)
		#expect(live.isActive)
		#expect(location.starts == 1)
		#expect(location.stops == 0)
		#expect(speech.messages.suffix(2) == ["Live Mode switched to Driving.", "Driving already selected."])
		live.stop()
	}

	@Test func movementContinuesDuringSlowFetchAndOldFetchCannotOverwriteRestart() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		map.suspend = true
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 1)
		await settle()
		for index in 0..<6 {
			clock.date = clock.date.addingTimeInterval(20)
			location.continuation?.yield(context(Double(index) * 0.0004))
			await settle()
			#expect(!live.checkTimeouts())
		}
		#expect(map.requests == 1)
		live.stop()
		live.start(mode: .walking, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		await settle()
		let expected = speech.messages
		map.continuation?.resume(returning: MapDataSet(intersections: [], roads: [highway()]))
		map.continuation = nil
		await settle()
		#expect(live.isActive)
		#expect(speech.messages == expected)
		live.stop()
	}

	@Test func missingLocationsHaveTheirOwnBoundedShutdownReason() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		await settle()
		location.continuation?.yield(context())
		await settle()
		clock.date = clock.date.addingTimeInterval(301)
		#expect(live.checkTimeouts())
		#expect(speech.messages.last == "Live Mode stopped because no recent location updates are available.")
		#expect(location.stops == 1)
	}

	@Test func freshStationaryReadingsStillStopLiveAndTransientErrorsAreRecoverable() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 1)
		await settle()
		for _ in 0..<5 {
			var sample = context()
			sample.speedMetersPerSecond = 0
			location.continuation?.yield(sample)
			await settle()
			clock.date = clock.date.addingTimeInterval(20)
		}
		#expect(!live.isActive)
		#expect(speech.messages.last == "Live Mode stopped because you haven't moved for 1 minute.")
		#expect(LiveLocationProvider.isRecoverable(CLError(.locationUnknown)))
		#expect(LiveLocationProvider.isRecoverable(CLError(.network)))
		#expect(!LiveLocationProvider.isRecoverable(CLError(.denied)))
	}

	@Test func drivingContinuesSpeakingSuccessiveIntersections() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		var road = highway("residential")
		road.name = "Oak Street"
		road.routeReference = nil
		map.data.roads = [road]
		map.data.intersections = [
			IntersectionCandidate(id: "first", names: ["Oak Street", "First Street"], coordinate: context(0.001).coordinate),
			IntersectionCandidate(id: "second", names: ["Oak Street", "Second Street"], coordinate: context(0.004).coordinate)
		]
		let live = coordinator(location, map, speech, clock)
		var prefs = AppPrefs()
		prefs.areaMode = .off
		prefs.spokenIntersectionCount = .one
		live.start(mode: .driving, prefs: prefs, speechSettings: settings, stationaryMinutes: 5)
		await settle()
		location.continuation?.yield(context())
		await settle()
		#expect(speech.messages.last?.contains("First Street") == true)
		clock.date = clock.date.addingTimeInterval(20)
		location.continuation?.yield(context(0.002))
		await settle()
		#expect(speech.messages.last?.contains("Second Street") == true)
		#expect(live.isActive)
		#expect(location.stops == 0)
		#expect(map.requests == 1)
		live.stop()
	}

	@Test func uncoveredDrivingMapRefreshIsBoundedAndFailuresBackOffAfterModeSwitch() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .walking, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 10)
		await settle()
		location.continuation?.yield(context())
		await settle()
		map.failure = URLError(.timedOut)
		live.switchMode(to: .driving)
		location.continuation?.yield(context(0.001))
		await settle()
		#expect(map.requests == 2)
		for _ in 0..<4 {
			clock.date = clock.date.addingTimeInterval(30)
			location.continuation?.yield(context(0.02))
			await settle()
		}
		#expect(map.requests == 2)
		clock.date = clock.date.addingTimeInterval(61)
		map.failure = nil
		location.continuation?.yield(context(0.02))
		await settle()
		#expect(map.requests == 3)
		clock.date = clock.date.addingTimeInterval(59)
		location.continuation?.yield(context(0.04))
		await settle()
		#expect(map.requests == 3)
		clock.date = clock.date.addingTimeInterval(1)
		location.continuation?.yield(context(0.04))
		await settle()
		#expect(map.requests == 4)
		#expect(live.isActive)
		live.stop()
	}

	@Test func lostLocationRecoveryDoesNotCountTheGapAsStationary() {
		var monitor = LiveMovementMonitor()
		let start = Date()
		monitor.reset(at: start)
		monitor.record(context(), at: start)
		#expect(!monitor.hasTimedOut(after: 1, at: start.addingTimeInterval(70)))
		monitor.record(context(), at: start.addingTimeInterval(75))
		#expect(!monitor.hasTimedOut(after: 1, at: start.addingTimeInterval(76)))
	}

	@Test func locationFailureTurnsOffOnceAndOldStreamCannotStopRestart() async {
		let location = LiveTestLocation(), map = LiveTestMap(), speech = LiveTestSpeech(), clock = LiveTestClock()
		let live = coordinator(location, map, speech, clock)
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		await settle()
		let oldStream = location.continuation
		oldStream?.finish(throwing: CLError(.denied))
		await settle()
		#expect(!live.isActive)
		#expect(speech.messages.last == "Live Mode stopped because location is unavailable.")
		live.start(mode: .driving, prefs: AppPrefs(), speechSettings: settings, stationaryMinutes: 5)
		await settle()
		oldStream?.finish(throwing: CLError(.denied))
		await settle()
		#expect(live.isActive)
		#expect(location.stops == 1)
		live.stop()
	}

	@Test func highwayQueriesRetainUnnamedHighwaysOnlyWhenRequested() async throws {
		let capture = LiveQueryCapture()
		var client = MapDataClient()
		client.endpoint = URL(string: "https://live-query-test.invalid/api")!
		client.fallbackEndpoints = []
		client.requestHandler = { request in
			await capture.record(String(data: request.httpBody ?? Data(), encoding: .utf8)?.removingPercentEncoding ?? "")
			return MapHTTPResponse(data: Data(#"{"elements":[]}"#.utf8),
								   response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		_ = try await client.freshMapData(near: context().coordinate, radiusMeters: 1_200, options: MapDetailOptions())
		_ = try await client.freshMapData(near: context().coordinate, radiusMeters: 1_200, options: MapDetailOptions(includeHighways: true))
		let queries = await capture.queries
		#expect(queries.count == 2)
		#expect(!queries[0].contains("motorway"))
		#expect(queries[1].contains(#"["highway"~"^(motorway|motorway_link|trunk|trunk_link)$"];"#))
		#expect(queries[1].contains("around:1200"))
	}

	@Test func trunkAccessRestrictionAloneDoesNotEstablishExpressway() throws {
		let json = #"{"elements":[{"type":"node","id":1,"lat":37,"lon":-122},{"type":"node","id":2,"lat":37.01,"lon":-122},{"type":"way","id":10,"nodes":[1,2],"tags":{"highway":"trunk","motorroad":"yes"}},{"type":"way","id":11,"nodes":[1,2],"tags":{"highway":"trunk","expressway":"yes"}}]}"#
		let response = try JSONDecoder().decode(OverpassResponse.self, from: Data(json.utf8))
		let roads = IntersectionBuilder().mapData(from: response, options: MapDetailOptions(includeHighways: true)).roads
		#expect(roads.first?.limitedAccess == false)
		#expect(roads.last?.limitedAccess == true)
	}

	@Test func highwayDataIsOptInAndUnnamedRampsArePreservedWithoutCityIntersections() throws {
		let json = #"{"elements":[{"type":"node","id":1,"lat":37,"lon":-122},{"type":"node","id":2,"lat":37.01,"lon":-122},{"type":"way","id":10,"nodes":[1,2],"tags":{"highway":"motorway","ref":"I-280","oneway":"yes"}},{"type":"way","id":11,"nodes":[1,2],"tags":{"highway":"motorway_link"}}]}"#
		let response = try JSONDecoder().decode(OverpassResponse.self, from: Data(json.utf8))
		let builder = IntersectionBuilder()
		#expect(builder.mapData(from: response).roads.isEmpty)
		let data = builder.mapData(from: response, options: MapDetailOptions(includeHighways: true))
		#expect(data.roads.count == 2)
		#expect(data.intersections.isEmpty)
		#expect(data.roads.first?.routeReference == "I-280")
		#expect(data.roads.last?.name == "")
		#expect(Set([MapDetailOptions(), MapDetailOptions(includeHighways: true)]).count == 2)
	}
}

private actor LiveQueryCapture {
	var queries: [String] = []
	func record(_ query: String) { queries.append(query) }
}
