import CoreLocation
import Foundation
import Testing
@testable import Intersector

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct OverpassPolicyTests {
    private let area = OverpassMapArea(latitude: 40.758, longitude: -73.9855, radius: 225, options: "false|false|false")
    private let payload = Data("{\"elements\":[]}".utf8)

    @Test func cacheSurvivesRestartAndHonorsCoverageOptionsAndRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("roads.json")
        let first = OverpassRoadResponseCache(fileURL: file)
        let started = Date()
        await first.store(payload, for: area, requestedAt: started)
        let restored = OverpassRoadResponseCache(fileURL: file)
        #expect(await restored.value(for: area) == payload)
        var moved = area; moved.latitude += 0.02
        #expect(await restored.value(for: moved) == nil)
        var options = area; options.options = "true|false|false"
        #expect(await restored.value(for: options) == nil)
        var larger = area; larger.radius = 375
        #expect(await restored.value(for: larger) == nil)
        #expect(await restored.value(for: area, minimumRequestedAt: started.addingTimeInterval(1)) == nil)
    }

    @Test func expiredCorruptAndOversizedArchivesDoNotProvideData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("roads.json")
        let now = Date()
        let first = OverpassRoadResponseCache(fileURL: file, now: { now })
        await first.store(payload, for: area, requestedAt: now)
        let expired = OverpassRoadResponseCache(fileURL: file, now: { now.addingTimeInterval(901) })
        #expect(await expired.value(for: area) == nil)
        try Data("corrupt".utf8).write(to: file)
        let corrupt = OverpassRoadResponseCache(fileURL: file)
        #expect(await corrupt.value(for: area) == nil)
        await corrupt.store(Data(repeating: 0, count: 8 * 1024 * 1024 + 1), for: area, requestedAt: now)
        #expect(await corrupt.value(for: area) == nil)
    }

    @Test func lateDownloadCannotReplaceNewerPersistedResponse() async {
        let cache = OverpassRoadResponseCache()
        let now = Date()
        await cache.store(Data("new".utf8), for: area, requestedAt: now)
        await cache.store(Data("old".utf8), for: area, requestedAt: now.addingTimeInterval(-1))
        #expect(await cache.value(for: area) == Data("new".utf8))
    }

    @Test func diskCacheIsBoundedToFourAreas() async {
        let cache = OverpassRoadResponseCache()
        for index in 0..<5 {
            var next = area; next.latitude += Double(index)
            await cache.store(payload, for: next, requestedAt: Date())
        }
        #expect(await cache.value(for: area) == nil)
        var latest = area; latest.latitude += 4
        #expect(await cache.value(for: latest) == payload)
    }

    @Test func retryAfterSecondsAndDateAreNotShortenedByGenericCooldown() async throws {
        let endpoint = URL(string: "https://rate-test.example/interpreter")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let health = OverpassEndpointHealth(now: { now })
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]))
        await health.recordResponse(response)
        await health.markTemporaryFailure(endpoint)
        #expect(await health.retryDate(for: endpoint) == now.addingTimeInterval(120))
        #expect(await health.orderedEndpoints(primary: endpoint, fallbacks: []).isEmpty)
        let later = OverpassEndpointHealth(now: { now.addingTimeInterval(70) })
        let dateResponse = try #require(HTTPURLResponse(url: endpoint, statusCode: 406, httpVersion: nil, headerFields: ["Retry-After": "Tue, 14 Nov 2023 22:18:20 GMT"]))
        await later.recordResponse(dateResponse)
        #expect(await later.retryDate(for: endpoint) == now.addingTimeInterval(300))
        #expect(await later.orderedEndpoints(primary: endpoint, fallbacks: []).isEmpty)
    }

    @Test func neighborhoodRateLimitStopsRotationAndBlocksRoadRequestToSameServer() async throws {
        let primary = URL(string: "https://rate-primary-\(UUID().uuidString).example/interpreter")!
        let fallback = URL(string: "https://rate-fallback-\(UUID().uuidString).example/interpreter")!
        let health = OverpassEndpointHealth()
        let calls = OverpassCalls()
        var places = NeighborhoodProvider()
        places.endpoint = primary; places.fallbackEndpoints = [fallback]; places.endpointHealth = health
        places.requestHandler = { request in
            await calls.record(request)
            return MapHTTPResponse(data: Data(), response: HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }
        do {
            _ = try await places.neighborhoods(near: CLLocationCoordinate2D(latitude: 25.12345, longitude: -72), radiusMeters: 100)
            Issue.record("Expected rate limit")
        } catch {
            guard case MapDataError.serverError(429) = error else { Issue.record("Expected HTTP 429, got \(error)"); return }
        }
        #expect(await calls.urls == [primary])
        #expect(await health.orderedEndpoints(primary: primary, fallbacks: [fallback]) == [fallback])
    }

    @Test func generatedRequestUsesFormEncodingAndExplicitResources() async throws {
        var client = MapDataClient()
        client.endpoint = URL(string: "https://request-shape-\(UUID().uuidString).example")!
        client.fallbackEndpoints = []
        client.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Intersector/") == true)
            let body = String(data: request.httpBody!, encoding: .utf8)!
            let query = String(body.dropFirst(5)).removingPercentEncoding!
            #expect(body.hasPrefix("data="))
            #expect(query.contains("[timeout:10][maxsize:33554432]"))
            #expect(query.contains("out body qt;"))
            #expect(request.timeoutInterval == 30)
            return MapHTTPResponse(data: Data("{\"elements\":[]}".utf8), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await client.freshMapData(near: CLLocationCoordinate2D(latitude: 40.758, longitude: -73.9855), radiusMeters: 225)
    }

    @Test func freshRequestBypassesPersistedResponse() async throws {
        let cache = OverpassRoadResponseCache()
        await cache.store(payload, for: area, requestedAt: Date())
        var client = MapDataClient()
        client.responseCache = cache
        client.endpoint = URL(string: "https://fresh-disk-\(UUID().uuidString).example")!
        client.fallbackEndpoints = []
        let calls = OverpassCalls()
        client.requestHandler = { request in
            await calls.record(request)
            return MapHTTPResponse(data: Data("{\"elements\":[]}".utf8), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await client.freshMapData(near: CLLocationCoordinate2D(latitude: area.latitude, longitude: area.longitude), radiusMeters: area.radius)
        #expect(await calls.urls.count == 1)
    }
    @Test func restoredDataKeepsItsOriginalAgeInMemory() async throws {
        let old = Date().addingTimeInterval(-901)
        let cache = MapDataCache()
        let calls = ColdServerSequence()
        let coordinate = CLLocationCoordinate2D(latitude: area.latitude, longitude: area.longitude)
        let url = URL(string: "https://age.example")!
        _ = try await cache.data(near: coordinate, radiusMeters: 225) {
            _ = await calls.next(url)
            return MapDataSet(intersections: [], roads: [], cacheStoredAt: old, cacheRequestedAt: old)
        }
        _ = try await cache.data(near: coordinate, radiusMeters: 225) {
            _ = await calls.next(url)
            return MapDataSet(intersections: [], roads: [])
        }
        #expect(await calls.urls.count == 2)
    }

    @Test func restoredCoverageDoesNotMoveWithEachMemoryReuse() async throws {
        let cache = MapDataCache()
        let calls = ColdServerSequence()
        let url = URL(string: "https://coverage.example")!
        let original = area
        let first = CLLocationCoordinate2D(latitude: area.latitude + 0.001, longitude: area.longitude)
        _ = try await cache.data(near: first, radiusMeters: 225) {
            _ = await calls.next(url)
            return MapDataSet(intersections: [], roads: [], cacheArea: original)
        }
        let second = CLLocationCoordinate2D(latitude: area.latitude + 0.002, longitude: area.longitude)
        _ = try await cache.data(near: second, radiusMeters: 225) {
            _ = await calls.next(url)
            return MapDataSet(intersections: [], roads: [])
        }
        #expect(await calls.urls.count == 2)
    }

    @Test(arguments: [ReportKind.nearest, .upcoming])
    func queuedResponseBeyondOldTwelveSecondCutoffSucceeds(kind: ReportKind) async throws {
        var client = MapDataClient()
        client.endpoint = URL(string: "https://queue-\(UUID().uuidString).example")!
        client.fallbackEndpoints = []
        client.mapCache = MapDataCache()
        client.requestHandler = { request in
            try await Task.sleep(for: .seconds(13))
            return MapHTTPResponse(data: coldRoadFixture, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = OrientSvc(locationProvider: ColdTestLocation(), mapDataClient: client, neighborhoodProvider: FailingNeighborhoodProvider())
        let request = SiriIntersectionRequest { _ in service }
        var prefs = AppPrefs(); prefs.areaMode = .off; prefs.spokenIntersectionCount = .one
        let started = ContinuousClock.now
        #expect(try await request.response(for: kind, prefs: prefs).contains("First Street"))
        #expect(started.duration(to: .now) >= .seconds(13))
    }

    @Test func coldUpcomingThenNearestFailuresRecoverAndShareSuccessfulData() async throws {
        let primary = URL(string: "https://cold-primary-\(UUID().uuidString).example")!
        let fallback = URL(string: "https://cold-fallback-\(UUID().uuidString).example")!
        let sequence = ColdServerSequence()
        var client = MapDataClient()
        client.endpoint = primary; client.fallbackEndpoints = [fallback]
        client.endpointHealth = OverpassEndpointHealth()
        client.mapCache = MapDataCache()
        client.responseCache = OverpassRoadResponseCache()
        client.requestHandler = { request in
            let step = await sequence.next(request.url!)
            switch step {
            case 1, 2: throw URLError(.timedOut)
            case 3: return MapHTTPResponse(data: Data(), response: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            case 4: throw URLError(.networkConnectionLost)
            default: return MapHTTPResponse(data: coldRoadFixture, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let service = OrientSvc(locationProvider: ColdTestLocation(), mapDataClient: client, neighborhoodProvider: FailingNeighborhoodProvider())
        let request = SiriIntersectionRequest { _ in service }
        var prefs = AppPrefs(); prefs.areaMode = .off; prefs.spokenIntersectionCount = .one
        #expect(try await request.response(for: .upcoming, prefs: prefs) == "This is taking too long. Please try again.")
        #expect(try await request.response(for: .nearest, prefs: prefs) == "I couldn't connect. Check your internet connection and try again.")
        #expect(try await request.response(for: .nearest, prefs: prefs).contains("First Street"))
        #expect(try await request.response(for: .upcoming, prefs: prefs).contains("First Street"))
        #expect(await sequence.urls == [primary, fallback, primary, fallback, fallback])
    }

    @Test func coldProcessUsesPersistedMapWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("roads.json")
        var cachedArea = area; cachedArea.latitude = 40.7575
        await OverpassRoadResponseCache(fileURL: file).store(coldRoadFixture, for: cachedArea, requestedAt: Date())
        var client = MapDataClient()
        client.responseCache = OverpassRoadResponseCache(fileURL: file)
        client.mapCache = MapDataCache()
        client.requestHandler = { _ in Issue.record("Cold process should reuse disk coverage"); throw URLError(.notConnectedToInternet) }
        let service = OrientSvc(locationProvider: ColdTestLocation(), mapDataClient: client, neighborhoodProvider: FailingNeighborhoodProvider())
        let request = SiriIntersectionRequest { _ in service }
        var prefs = AppPrefs(); prefs.areaMode = .off; prefs.spokenIntersectionCount = .one
        #expect(try await request.response(for: .nearest, prefs: prefs).contains("First Street"))
        #expect(try await request.response(for: .upcoming, prefs: prefs).contains("First Street"))
    }

    @Test func cancelledDownloadDoesNotCreatePersistedSuccess() async throws {
        let cache = OverpassRoadResponseCache()
        let calls = OverpassCalls()
        var client = MapDataClient()
        client.endpoint = URL(string: "https://cancel-disk-\(UUID().uuidString).example")!
        client.fallbackEndpoints = []; client.responseCache = cache
        client.requestHandler = { request in
            await calls.record(request)
            try await Task.sleep(for: .seconds(30))
            return MapHTTPResponse(data: coldRoadFixture, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let configured = client
        let task = Task { try await configured.freshMapData(near: CLLocationCoordinate2D(latitude: 40.758, longitude: -73.9855), radiusMeters: 225) }
        while await calls.urls.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(await cache.value(for: area) == nil)
    }

}

private actor OverpassCalls {
    private(set) var urls: [URL] = []
    func record(_ request: URLRequest) { urls.append(request.url!) }
}

private struct ColdTestLocation: LocationProviding {
    func currentContext() async throws -> DeviceContext {
        DeviceContext(coordinate: CLLocationCoordinate2D(latitude: 40.7575, longitude: -73.9855), headingDegrees: 0)
    }
}
private actor ColdServerSequence {
    private(set) var urls: [URL] = []
    func next(_ url: URL) -> Int { urls.append(url); return urls.count }
}
private let coldRoadFixture = Data(#"{"elements":[{"type":"node","id":1,"lat":40.757,"lon":-73.9855},{"type":"node","id":2,"lat":40.758,"lon":-73.9855},{"type":"node","id":3,"lat":40.759,"lon":-73.9855},{"type":"node","id":4,"lat":40.758,"lon":-73.9865},{"type":"node","id":5,"lat":40.758,"lon":-73.9845},{"type":"way","id":10,"nodes":[1,2,3],"tags":{"name":"Oak Street","highway":"residential"}},{"type":"way","id":11,"nodes":[4,2,5],"tags":{"name":"First Street","highway":"residential"}}]}"#.utf8)
