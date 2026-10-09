import CoreLocation
import Foundation
import Testing
@testable import Intersector

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SiriIntersectionRequestTests {
	private let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)

	@Test(arguments: [ReportKind.nearest, .upcoming])
	func noResultThenNewInvocationRefreshesAndSucceeds(kind: ReportKind) async throws {
		let cache = MapDataCache()
		let coordinate = origin
		_ = try await cache.data(near: coordinate, radiusMeters: 10_000) {
			MapDataSet(intersections: [], roads: [])
		}
		var cutoffs: [Date?] = []
		let request = SiriIntersectionRequest { cutoff in
			cutoffs.append(cutoff)
			return service(client: SiriCachedMap(cache: cache, cutoff: cutoff, data: goodData))
		}
		let first = try await response(kind, using: request)
		#expect(first == SiriIntersectionRequest.failureMessage(OrientError.noIntersections, kind: kind))
		let second = try await response(kind, using: request)
		#expect(second.contains("Oak Street"))
		#expect(second.contains("First Street"))
		#expect(!second.contains("response."))
		_ = try await response(kind, using: request)
		#expect(cutoffs.count == 3)
		#expect(cutoffs[0] == nil)
		#expect(cutoffs[1] != nil)
		#expect(cutoffs[2] == nil)
	}

	@Test(arguments: [ReportKind.nearest, .upcoming])
	func connectionFailureThenNewInvocationSucceeds(kind: ReportKind) async throws {
		var count = 0
		let request = SiriIntersectionRequest { _ in
			count += 1
			return service(client: SiriControlledMap(data: goodData,
				error: count == 1 ? URLError(.notConnectedToInternet) : nil))
		}
		#expect(try await response(kind, using: request) == "I couldn't connect. Check your internet connection and try again.")
		#expect(try await response(kind, using: request).contains("First Street"))
		#expect(count == 2)
	}

	@Test(arguments: [ReportKind.nearest, .upcoming])
	func timeoutThenNewInvocationHasFreshTimeAllowance(kind: ReportKind) async throws {
		var count = 0
		let request = SiriIntersectionRequest(timeout: .milliseconds(200)) { _ in
			count += 1
			return service(client: SiriControlledMap(data: goodData,
				delay: count == 1 ? .seconds(30) : .milliseconds(40)))
		}
		#expect(try await response(kind, using: request) == "This is taking too long. Please try again.")
		#expect(try await response(kind, using: request).contains("First Street"))
		#expect(count == 2)
	}

	@Test(arguments: [ReportKind.nearest, .upcoming], [1, 2, 3])
	func structuredRequestGetsFreshAttemptAfterConnectionFailure(kind: ReportKind, rank: Int) async throws {
		var count = 0
		let request = SiriIntersectionRequest { _ in
			count += 1
			return service(client: SiriControlledMap(data: goodData, error: count == 1 ? URLError(.networkConnectionLost) : nil))
		}
		do { _ = try await request.report(for: kind, rank: rank, prefs: AppPrefs()); Issue.record("Expected connection loss") }
		catch { #expect((error as? URLError)?.code == .networkConnectionLost) }
		let report = try await request.report(for: kind, rank: rank, prefs: AppPrefs())
		#expect(report.cross.contains(["First Street", "Second Street", "Third Street"][rank - 1]))
		#expect(count == 2)
	}

	@Test(arguments: [ReportKind.nearest, .upcoming], [false, true])
	func intersectionDetailsReachSiriAndRespectSavedSetting(kind: ReportKind, enabled: Bool) async throws {
		var data = goodData
		for index in data.intersections.indices {
			data.intersections[index].intersectionDetails = IntersectionDetails(
				isSignalized: true, hasPedestrianIsland: true, isStreetIntersection: true
			)
		}
		let mappedData = data
		let request = SiriIntersectionRequest { _ in service(client: SiriControlledMap(data: mappedData)) }
		let suiteName = "SiriIntersectionDetails.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		defaults.set(enabled, forKey: "includeIntersectionDetails")
		let prefs = AppPrefs.saved(from: defaults)
		let text = try await response(kind, using: request, prefs: prefs)
		#expect(text.contains("signalized intersection") == enabled)
		#expect(text.contains("pedestrian island") == enabled)
		#expect(!text.contains("audible"))
		for rank in [2, 3] {
			let report = try await request.report(for: kind, rank: rank, prefs: prefs)
			let rankedText = report.text(with: prefs, rank: rank)
			#expect(rankedText.contains("signalized intersection") == enabled)
			#expect(rankedText.contains("pedestrian island") == enabled)
		}
	}

	@Test func slowNeighborhoodDoesNotDiscardIntersectionAtDeadline() async throws {
		let svc = OrientSvc(locationProvider: FakeLocationProvider(context: DeviceContext(coordinate: origin, headingDegrees: 0)),
			mapDataClient: StaticMapDataClient(data: goodData), neighborhoodProvider: SlowSiriNeighborhood())
		var prefs = AppPrefs()
		prefs.areaMode = .near
		prefs.announcementOptions.includeNeighborhood = true
		let configured = prefs
		let report = try await LookupAttempt.run(timeout: .milliseconds(700)) { try await svc.report(.nearest, prefs: configured) }
		#expect(report.cross.contains("First Street"))
		#expect(report.area == nil)
	}

	@Test func cancellingOneSiriRequestDoesNotCancelAnother() async throws {
		var count = 0
		let request = SiriIntersectionRequest { _ in
			count += 1
			return service(client: SiriControlledMap(data: goodData, delay: count == 1 ? .seconds(30) : .milliseconds(30)))
		}
		let first = Task { try await request.report(for: .nearest, prefs: AppPrefs()) }
		while count == 0 { await Task.yield() }
		let second = Task { try await request.report(for: .nearest, prefs: AppPrefs()) }
		while count < 2 { await Task.yield() }
		first.cancel()
		do { _ = try await first.value; Issue.record("Expected cancellation") } catch is CancellationError {}
		#expect(try await second.value.cross.contains("First Street"))
	}

	@Test func cancellationDoesNotBecomeSpokenFailure() async throws {
		let request = SiriIntersectionRequest { _ in
			service(client: SiriControlledMap(data: goodData, delay: .seconds(30)))
		}
		let task = Task { try await response(.nearest, using: request) }
		task.cancel()
		do { _ = try await task.value; Issue.record("Expected cancellation") }
		catch is CancellationError {}
	}

	@Test func failureWordingIsPlainAndSpecific() {
		#expect(SiriIntersectionRequest.failureMessage(MapDataError.serversCoolingDown, kind: .nearest) == "I can't get intersection information right now. Please wait a minute and try again.")
		#expect(SiriIntersectionRequest.failureMessage(MapDataError.serverError(429), kind: .upcoming) == "I can't get intersection information right now. Please wait a minute and try again.")
		#expect(SiriIntersectionRequest.failureMessage(OrientError.headingUnavailable, kind: .upcoming) == "I couldn't tell which way you're facing. Hold your device steady and try again.")
	}

	private func response(_ kind: ReportKind, using request: SiriIntersectionRequest, prefs: AppPrefs = AppPrefs()) async throws -> String {
		if kind == .nearest {
			return try await NearestIntersectionIntent().response(using: request, prefs: prefs)
		}
		return try await UpcomingIntersectionIntent().response(using: request, prefs: prefs)
	}

	private func service(client: any MapDataFetching) -> OrientSvc {
		OrientSvc(locationProvider: FakeLocationProvider(context: DeviceContext(coordinate: origin, headingDegrees: 0)),
			mapDataClient: client, neighborhoodProvider: FailingNeighborhoodProvider())
	}

	private var goodData: MapDataSet {
		MapDataSet(intersections: [IntersectionCandidate(id: "first", names: ["Oak Street", "First Street"],
			coordinate: CLLocationCoordinate2D(latitude: origin.latitude + 0.001, longitude: origin.longitude)),
			IntersectionCandidate(id: "second", names: ["Oak Street", "Second Street"], coordinate: CLLocationCoordinate2D(latitude: origin.latitude + 0.0015, longitude: origin.longitude)),
			IntersectionCandidate(id: "third", names: ["Oak Street", "Third Street"], coordinate: CLLocationCoordinate2D(latitude: origin.latitude + 0.002, longitude: origin.longitude))],
			roads: [MapRoad(id: "oak", name: "Oak Street", nodeIDs: [1, 2], coordinates: [
				CLLocationCoordinate2D(latitude: origin.latitude - 0.002, longitude: origin.longitude),
				CLLocationCoordinate2D(latitude: origin.latitude + 0.003, longitude: origin.longitude)])])
	}
}

private struct SiriCachedMap: MapDataFetching {
	let cache: MapDataCache
	let cutoff: Date?
	let data: MapDataSet
	func intersections(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> [IntersectionCandidate] {
		try await mapData(near: coordinate, radiusMeters: radiusMeters, options: options).intersections
	}
	func mapData(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> MapDataSet {
		try await cache.data(near: coordinate, radiusMeters: 10_000, minimumRequestedAt: cutoff) { data }
	}
}

private struct SiriControlledMap: MapDataFetching {
	let data: MapDataSet
	var error: URLError? = nil
	var delay: Duration = .zero
	func intersections(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> [IntersectionCandidate] {
		try await mapData(near: coordinate, radiusMeters: radiusMeters, options: options).intersections
	}
	func mapData(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> MapDataSet {
		if let error { throw error }
		if delay > .zero { try await Task.sleep(for: delay) }
		return data
	}
}

private struct SlowSiriNeighborhood: NeighborhoodProviding {
	func neighborhoods(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance) async throws -> [NeighborhoodCandidate] {
		try await Task.sleep(for: .seconds(30))
		return []
	}
}
