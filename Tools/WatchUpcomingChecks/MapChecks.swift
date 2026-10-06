import Foundation
import CoreLocation

@main struct MapChecks {
    static let origin = CLLocationCoordinate2D(latitude: 40.758, longitude: -73.9855)
    nonisolated static let empty = Data("{\"elements\":[]}".utf8)
    @MainActor static func client() -> WatchMapDataClient {
        var client = WatchMapDataClient()
        client.responseCache = OverpassRoadResponseCache()
        client.endpoint = URL(string: "https://watch-test-\(UUID().uuidString).example")!
        client.fallbackEndpoints = []
        return client
    }
    nonisolated static func response(_ request: URLRequest, data: Data = empty) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    nonisolated static let roadFixture = Data(#"{"elements":[{"type":"node","id":1,"lat":40.757,"lon":-73.9855},{"type":"node","id":2,"lat":40.758,"lon":-73.9855},{"type":"node","id":3,"lat":40.759,"lon":-73.9855},{"type":"node","id":4,"lat":40.758,"lon":-73.9865},{"type":"node","id":5,"lat":40.758,"lon":-73.9845},{"type":"way","id":10,"nodes":[1,2,3],"tags":{"name":"Oak Street","highway":"residential"}},{"type":"way","id":11,"nodes":[4,2,5],"tags":{"name":"First Street","highway":"residential"}}]}"#.utf8)
    @MainActor static func main() async throws {
        if CommandLine.arguments.count > 1 {
            for path in CommandLine.arguments.dropFirst() {
                let response = try JSONDecoder().decode(WatchOverpassResponse.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                precondition(response.remark?.isEmpty != false)
                let started = ContinuousClock.now
                let map = WatchIntersectionBuilder().mapData(from: response, options: WatchMapDetailOptions())
                precondition(!map.intersections.isEmpty)
                print("Downloaded map: \(response.elements.count) elements, \(map.intersections.count) intersections, processing \(started.duration(to: .now))")
            }
            return
        }
        // An offline failure must leave the endpoint available for an explicit retry.
        var offline = client()
        offline.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await offline.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected failure") }
        catch { precondition((error as? URLError)?.code == .notConnectedToInternet) }
        let log = WatchRequestLog()
        offline.requestHandler = { request in await log.record(); return response(request) }
        _ = try await offline.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        _ = try await offline.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        let count = await log.count
        precondition(count == 1, "Same lookup must reuse completed identical query")

        var fallback = client()
        let first = fallback.endpoint
        fallback.fallbackEndpoints = [URL(string: "https://watch-fallback-\(UUID().uuidString).example")!]
        let fallbackLog = WatchRequestLog()
        fallback.requestHandler = { request in
            await fallbackLog.record()
            let body = request.url == first ? Data("{\"remark\":\"runtime error: timeout\",\"elements\":[]}".utf8) : empty
            return response(request, data: body)
        }
        _ = try await fallback.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        let fallbackCount = await fallbackLog.count
        precondition(fallbackCount == 2, "Incomplete response must use fallback")

        var slow = client()
        let last = URL(string: "https://watch-last-\(UUID().uuidString).example")!
        slow.fallbackEndpoints = [URL(string: "https://watch-slow-\(UUID().uuidString).example")!, last]
        let slowLog = WatchRequestLog()
        slow.requestHandler = { request in
            await slowLog.record()
            precondition(request.timeoutInterval == 30)
            if request.url != last { throw URLError(.timedOut) }
            return response(request)
        }
        let configured = slow
        _ = try await LookupAttempt.run {
            try await configured.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        }
        let slowCount = await slowLog.count
        precondition(slowCount == 3, "Each fallback must get its full allowance")

        // A queued 13-second response exceeds the former cutoff after eight seconds acquiring location.
        var delayed = client()
        delayed.fallbackEndpoints = [URL(string: "https://unused-a.example")!, URL(string: "https://unused-b.example")!]
        let delayedLog = WatchRequestLog()
        delayed.requestHandler = { request in
            await delayedLog.record()
            precondition(request.timeoutInterval == 30)
            try await Task.sleep(for: .seconds(13))
            return response(request, data: roadFixture)
        }
        let delayedClient = delayed
        let map = try await LookupAttempt.run {
            try await Task.sleep(for: .seconds(8))
            return try await delayedClient.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        }
        precondition(!map.intersections.isEmpty, "Slow valid data must produce an intersection")
        let delayedCount = await delayedLog.count
        precondition(delayedCount == 1, "Successful primary must not trigger fallbacks")

        var retry = client()
        retry.requestHandler = { _ in throw URLError(.timedOut) }
        do { _ = try await retry.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected timeout") }
        catch { precondition((error as? URLError)?.code == .timedOut) }
        retry.requestHandler = { request in response(request, data: roadFixture) }
        let recovered = try await retry.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        precondition(!recovered.intersections.isEmpty)

        var limited = client()
        let limitedLog = WatchRequestLog()
        limited.requestHandler = { _ in await limitedLog.record(); throw WatchReportError.serverError(429) }
        do { _ = try await limited.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected limit") }
        catch WatchReportError.serverError(429) {}
        do { _ = try await limited.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected cooldown") }
        catch WatchReportError.serversCoolingDown {}
        let limitedCount = await limitedLog.count
        precondition(limitedCount == 1, "Cooldown must prevent repeated server calls")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("roads.json")
        let area = OverpassMapArea(latitude: origin.latitude, longitude: origin.longitude, radius: 225, options: "false|false|false")
        await OverpassRoadResponseCache(fileURL: file).store(roadFixture, for: area, requestedAt: Date())
        var restored = client()
        restored.responseCache = OverpassRoadResponseCache(fileURL: file)
        restored.requestHandler = { _ in fatalError("Persisted cold Watch coverage must not download again") }
        let coldMap = try await restored.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        precondition(!coldMap.intersections.isEmpty)

        var headers = client()
        headers.requestHandler = { request in
            let query = String(data: request.httpBody!, encoding: .utf8)!.dropFirst(5).removingPercentEncoding!
            precondition(query.contains("[timeout:10][maxsize:33554432]"))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }
        do { _ = try await headers.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected rate limit") }
        catch WatchReportError.serverError(429) {}
        let retryDate = await headers.endpointHealth.retryDate(for: headers.endpoint)
        precondition(retryDate.map { $0.timeIntervalSinceNow > 110 } == true)

        print("Watch map checks passed: offline retry, request reuse, incomplete response fallback, full server allowance, slow valid response after location delay, timeout retry, cooldown, disk restoration, explicit resource limits, Retry-After")
    }
}
private actor WatchRequestLog {
    private(set) var count = 0
    func record() { count += 1 }
}
