import Foundation
import CoreLocation

@main struct CrossingChecks {
    @MainActor static func main() throws {
        let fixtures = try JSONDecoder().decode(CrossingFixtures<WatchOverpassResponse>.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let builder = WatchIntersectionBuilder()
        for fixture in fixtures.cases {
            for walkingPaths in [false, true] {
                let options = WatchMapDetailOptions(includeCrossings: true, includeWalkingPaths: walkingPaths)
                let core = builder.mapData(from: fixture.response, options: WatchMapDetailOptions(includeWalkingPaths: walkingPaths))
                precondition(core.intersections.allSatisfy { !$0.id.hasPrefix("crossing-") })
                let direct = builder.mapData(from: fixture.response, options: options)
                let enriched = builder.mapData(from: fixture.response, options: options, coreData: core)
                let repeated = builder.mapData(from: fixture.response, options: options, coreData: enriched)
                for map in [direct, enriched, repeated] {
                    let actual = map.intersections.filter {
                        $0.id.hasPrefix("crossing-") && fixture.includes(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, roads: $0.roadNames)
                    }
                    precondition(actual.count == fixture.expected.count, "\(fixture.name): count \(actual.count), expected \(fixture.expected.count)")
                    precondition(Set(actual.map(\.id)) == Set(fixture.expected.map(\.id)), "\(fixture.name): identities")
                    for expected in fixture.expected {
                        let candidate = actual.first { $0.id == expected.id }!
                        precondition(candidate.roadNames == [expected.road], "\(fixture.name): road")
                        precondition(abs(candidate.coordinate.latitude - expected.lat) < 0.00000001, "\(fixture.name): latitude")
                        precondition(abs(candidate.coordinate.longitude - expected.lon) < 0.00000001, "\(fixture.name): longitude")
                        precondition((candidate.intersectionDetails?.isSignalized ?? false) == expected.signal, "\(fixture.name): signal")
                    }
                }
            }
            print("PASS: \(fixture.name)")
        }
        print("PASS: \(fixtures.cases.count) crossing fixtures, direct/enrichment/repeated enrichment, paths on/off")
    }
}
