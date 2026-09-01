import AVFoundation
import CoreLocation
import Foundation
import Testing
@testable import Intersector

@MainActor
struct LiveModeTests {
	@Test func speechRatePercentageMapsAcrossTheSystemSpeechRange() {
		#expect(SystemSpeechController.speechRate(forPercent: 0) == AVSpeechUtteranceMinimumSpeechRate)
		#expect(SystemSpeechController.speechRate(forPercent: 100) == AVSpeechUtteranceMaximumSpeechRate)
		#expect(SystemSpeechController.speechRate(forPercent: -10) == AVSpeechUtteranceMinimumSpeechRate)
		#expect(SystemSpeechController.speechRate(forPercent: 110) == AVSpeechUtteranceMaximumSpeechRate)
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

	@Test func stationaryMonitorIgnoresGpsDriftAndResetsAfterRealMovement() {
		let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)
		let start = Date(timeIntervalSince1970: 10_000)
		var monitor = LiveMovementMonitor()
		monitor.reset(at: start)
		monitor.record(
			DeviceContext(coordinate: origin, headingDegrees: nil, horizontalAccuracy: 10),
			at: start
		)
		monitor.record(
			DeviceContext(
				coordinate: CLLocationCoordinate2D(latitude: 37.00005, longitude: -122),
				headingDegrees: nil,
				horizontalAccuracy: 10
			),
			at: start.addingTimeInterval(240)
		)

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
