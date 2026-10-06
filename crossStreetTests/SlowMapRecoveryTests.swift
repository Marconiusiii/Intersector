import CoreLocation
import Foundation
import Testing
@testable import Intersector

@Suite(.timeLimit(.minutes(3)))
@MainActor
struct SlowMapRecoveryTests {
    @Test(arguments: [ReportKind.nearest, .upcoming], ["phone", "Siri", "Get"])
    func validTenSecondResponseAfterLocationDelaySucceeds(kind: ReportKind, entry: String) async throws {
        var client = MapDataClient()
        client.endpoint = URL(string: "https://slow-valid-\(UUID().uuidString).example")!
        client.fallbackEndpoints = [URL(string: "https://unused-one.example")!, URL(string: "https://unused-two.example")!]
        let log = SlowResponseLog()
        client.requestHandler = { request in
            await log.record(request.timeoutInterval)
            try await Task.sleep(for: .seconds(10))
            return MapHTTPResponse(data: slowRoadFixture, response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let service = OrientSvc(locationProvider: DelayedRecoveryLocation(), mapDataClient: FreshRecoveryMap(client: client), neighborhoodProvider: FailingNeighborhoodProvider())
        var prefs = AppPrefs()
        prefs.areaMode = .off
        prefs.spokenIntersectionCount = .one
        let request = SiriIntersectionRequest { _ in service }
        let started = ContinuousClock.now
        let text: String
        switch entry {
        case "Siri": text = try await request.response(for: kind, prefs: prefs)
        case "Get": text = try await request.report(for: kind, prefs: prefs).text(with: prefs)
        default: text = try await service.report(kind, prefs: prefs).text(with: prefs)
        }
        #expect(text.contains("First Street"))
        #expect(started.duration(to: .now) >= .seconds(17))
        #expect(await log.allowances == [12])
    }
}

private struct DelayedRecoveryLocation: LocationProviding {
    func currentContext() async throws -> DeviceContext {
        try await Task.sleep(for: .seconds(8))
        return DeviceContext(coordinate: CLLocationCoordinate2D(latitude: 40.7575, longitude: -73.9855), headingDegrees: 0)
    }
}

// Avoid shared map-cache hits between parallel cases; exercise the real network
// request policy and real decoder/builder for every tested entry point.
private struct FreshRecoveryMap: MapDataFetching {
    let client: MapDataClient
    func mapData(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> MapDataSet {
        try await client.freshMapData(near: coordinate, radiusMeters: radiusMeters, options: options)
    }
    func intersections(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance, options: MapDetailOptions) async throws -> [IntersectionCandidate] {
        try await mapData(near: coordinate, radiusMeters: radiusMeters, options: options).intersections
    }
}
private actor SlowResponseLog {
    private(set) var allowances: [TimeInterval] = []
    func record(_ allowance: TimeInterval) { allowances.append(allowance) }
}
private let slowRoadFixture = Data(#"{"elements":[{"type":"node","id":1,"lat":40.757,"lon":-73.9855},{"type":"node","id":2,"lat":40.758,"lon":-73.9855},{"type":"node","id":3,"lat":40.759,"lon":-73.9855},{"type":"node","id":4,"lat":40.758,"lon":-73.9865},{"type":"node","id":5,"lat":40.758,"lon":-73.9845},{"type":"way","id":10,"nodes":[1,2,3],"tags":{"name":"Oak Street","highway":"residential"}},{"type":"way","id":11,"nodes":[4,2,5],"tags":{"name":"First Street","highway":"residential"}}]}"#.utf8)
