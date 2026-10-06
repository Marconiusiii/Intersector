import Foundation
import CoreLocation

@main struct MapChecks {
    static let origin = CLLocationCoordinate2D(latitude: 40.758, longitude: -73.9855)
    nonisolated static let empty = Data("{\"elements\":[]}".utf8)
    @MainActor static func client() -> WatchMapDataClient {
        var client = WatchMapDataClient()
        client.endpoint = URL(string: "https://watch-test-\(UUID().uuidString).example")!
        client.fallbackEndpoints = []
        return client
    }
    nonisolated static func response(_ request: URLRequest, data: Data = empty) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    @MainActor static func main() async throws {
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
            if request.url != last { try await Task.sleep(for: .seconds(10)) }
            return response(request)
        }
        let configured = slow
        _ = try await LookupAttempt.run(timeout: .seconds(1)) {
            try await configured.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions())
        }
        let slowCount = await slowLog.count
        precondition(slowCount == 3, "Fallbacks must share the deadline")

        var limited = client()
        let limitedLog = WatchRequestLog()
        limited.requestHandler = { _ in await limitedLog.record(); throw WatchReportError.serverError(429) }
        do { _ = try await limited.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected limit") }
        catch WatchReportError.serverError(429) {}
        do { _ = try await limited.mapData(near: origin, radiusMeters: 225, options: WatchMapDetailOptions()); fatalError("Expected cooldown") }
        catch WatchReportError.serversCoolingDown {}
        let limitedCount = await limitedLog.count
        precondition(limitedCount == 1, "Cooldown must prevent repeated server calls")
        print("Watch map checks passed: offline retry, request reuse, incomplete response fallback, shared deadline, cooldown")
    }
}
private actor WatchRequestLog {
    private(set) var count = 0
    func record() { count += 1 }
}
