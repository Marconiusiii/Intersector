import CoreLocation
import Foundation
import Testing
@testable import Intersector

private final class CrossingFixtureBundle: NSObject {}

@MainActor struct CrossingRegressionTests {
    @Test(arguments: 0..<18)
    func crossingMapInterpretation(caseIndex: Int) throws {
        let url = try #require(Bundle(for: CrossingFixtureBundle.self).url(forResource: "CrossingRegression", withExtension: "json"))
        let fixtures = try JSONDecoder().decode(CrossingFixtures<OverpassResponse>.self, from: Data(contentsOf: url))
        let fixture = fixtures.cases[caseIndex]
        let builder = IntersectionBuilder()
        for walkingPaths in [false, true] {
            let options = MapDetailOptions(includeCrossings: true, includeWalkingPaths: walkingPaths)
            let core = builder.mapData(from: fixture.response, options: MapDetailOptions(includeWalkingPaths: walkingPaths))
            #expect(core.intersections.allSatisfy { !$0.id.hasPrefix("crossing-") }, "\(fixture.name): crossings off")
            let direct = builder.mapData(from: fixture.response, options: options)
            let enriched = builder.mapData(from: fixture.response, options: options, coreData: core)
            let repeated = builder.mapData(from: fixture.response, options: options, coreData: enriched)
            for map in [direct, enriched, repeated] {
                let actual = map.intersections.filter {
                    $0.id.hasPrefix("crossing-") && fixture.includes(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, roads: $0.roadNames)
                }
                #expect(actual.count == fixture.expected.count, "\(fixture.name): crossing count")
                #expect(Set(actual.map(\.id)) == Set(fixture.expected.map(\.id)), "\(fixture.name): connection identities")
                for expected in fixture.expected {
                    let candidate = try #require(actual.first { $0.id == expected.id }, "\(fixture.name)")
                    #expect(candidate.roadNames == [expected.road], "\(fixture.name): road")
                    #expect(abs(candidate.coordinate.latitude - expected.lat) < 0.00000001, "\(fixture.name): latitude")
                    #expect(abs(candidate.coordinate.longitude - expected.lon) < 0.00000001, "\(fixture.name): longitude")
                    #expect((candidate.intersectionDetails?.isSignalized ?? false) == expected.signal, "\(fixture.name): signal detail")
                }
            }
        }
    }
}
