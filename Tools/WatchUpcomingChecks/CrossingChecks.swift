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
        for fixture in IntersectionDetailFixture.cases {
            for reversePaths in [false, true] {
                let response = try JSONDecoder().decode(WatchOverpassResponse.self, from: fixture.responseData(reversePaths: reversePaths))
                let options = WatchMapDetailOptions(includeCrossings: true)
                let core = builder.mapData(from: response, options: WatchMapDetailOptions())
                let direct = builder.mapData(from: response, options: options)
                let enriched = builder.mapData(from: response, options: options, coreData: core)
                let repeated = builder.mapData(from: response, options: options, coreData: enriched)
                for map in [direct, enriched, repeated] {
                    precondition(map.intersections.count == 1, "\(fixture.name): no extra results")
                    guard let candidate = map.intersections.first(where: { $0.id == fixture.candidateID }) else {
                        fatalError("\(fixture.name): result")
                    }
                    precondition((candidate.intersectionDetails?.spokenPhrases ?? []) == fixture.phrases, "\(fixture.name): phrases")
                    let report = WatchOrientationReport(kind: .nearest, cross: candidate.title, dist: "100 feet", relDir: "ahead", relDegrees: 0,
                                                        street: nil, crossStreet: nil, head: nil, area: nil, toward: nil,
                                                        intersectionDetails: candidate.intersectionDetails)
                    var prefs = WatchAppPrefs()
                    let plain = "Nearest: \(candidate.title), about 100 feet ahead"
                    precondition(report.text(with: prefs) == plain + ".", "\(fixture.name): setting off")
                    prefs.announcementOptions.includeIntersectionDetails = true
                    let suffix = fixture.phrases.isEmpty ? "" : ", " + fixture.phrases.joined(separator: ", ")
                    precondition(report.text(with: prefs) == plain + suffix + ".", "\(fixture.name): setting on")
                }
            }
            print("PASS: \(fixture.name)")
        }
        print("PASS: \(IntersectionDetailFixture.cases.count) detail fixtures, parsing and announcements, direct/enrichment/repeated enrichment, both path orders")
    }
}
