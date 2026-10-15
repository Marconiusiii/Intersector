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

@MainActor struct IntersectionDetailTests {
    @Test(arguments: IntersectionDetailFixture.cases.indices)
    func mappedDetails(caseIndex: Int) throws {
        let fixture = IntersectionDetailFixture.cases[caseIndex]
        for reversePaths in [false, true] {
            let response = try JSONDecoder().decode(OverpassResponse.self, from: fixture.responseData(reversePaths: reversePaths))
            let builder = IntersectionBuilder()
            let options = MapDetailOptions(includeCrossings: true)
            let core = builder.mapData(from: response)
            let direct = builder.mapData(from: response, options: options)
            let enriched = builder.mapData(from: response, options: options, coreData: core)
            let repeated = builder.mapData(from: response, options: options, coreData: enriched)
            for map in [direct, enriched, repeated] {
                #expect(map.intersections.count == 1, "\(fixture.name): no extra results")
                let candidate = try #require(map.intersections.first { $0.id == fixture.candidateID }, "\(fixture.name): result")
                #expect(candidate.intersectionDetails?.spokenPhrases ?? [] == fixture.phrases, "\(fixture.name): phrases")
                let report = OrientReport(kind: .nearest, cross: candidate.title, dist: "100 feet", relDir: "ahead", relDegrees: 0,
                                          street: nil, head: nil, area: nil, toward: nil, conf: .high,
                                          intersectionDetails: candidate.intersectionDetails)
                var prefs = AppPrefs()
                let plain = "Nearest: \(candidate.title), about 100 feet ahead"
                #expect(report.text(with: prefs) == plain + ".", "\(fixture.name): setting off")
                prefs.announcementOptions.includeIntersectionDetails = true
                let suffix = fixture.phrases.isEmpty ? "" : ", " + fixture.phrases.joined(separator: ", ")
                #expect(report.text(with: prefs) == plain + suffix + ".", "\(fixture.name): setting on")
            }
        }
    }
}

@MainActor struct CrossingMergeTests {
    @Test func laterJunctionSuppressesEarlierCrossings() throws {
        let builder = IntersectionBuilder()
        let options = MapDetailOptions(includeCrossings: true)
        func map(_ crossings: [Int], junction: Bool) throws -> MapDataSet {
            builder.mapData(from: try JSONDecoder().decode(OverpassResponse.self,
                from: CrossingMergeFixture.response(crossings: crossings, junction: junction)), options: options)
        }
        let partial = try map([3, 4, 5, 6], junction: false)
        let complete = try map([3, 4, 5, 6], junction: true)
        #expect(partial.intersections.count == 4)
        #expect(Set(complete.intersections.map(\.id)) == ["2", "crossing-6"])
        for merged in [partial.merging(complete), complete.merging(partial), partial.merging(complete).merging(partial)] {
            #expect(Set(merged.intersections.map(\.id)) == ["2", "crossing-6"])
        }
        let firstCorner = try map([4], junction: true)
        let secondCorner = try map([5], junction: true)
        #expect(firstCorner.intersections.count == 2)
        #expect(secondCorner.intersections.count == 2)
        #expect(firstCorner.merging(secondCorner).intersections.map(\.id) == ["2"])
        #expect(secondCorner.merging(firstCorner).intersections.map(\.id) == ["2"])
        #expect(firstCorner.merging(secondCorner).merging(firstCorner).intersections.map(\.id) == ["2"])
    }
}
