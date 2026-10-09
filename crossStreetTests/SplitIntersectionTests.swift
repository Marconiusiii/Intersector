import CoreLocation
import Testing
@testable import Intersector

@MainActor
struct SplitIntersectionTests {
    @Test(arguments: [false, true], [90.0, 270.0])
    func crossStreetOrderFollowsCompass(separateNodes: Bool, heading: Double) async throws {
        let fixture = SplitIntersectionFixture(separateNodes: separateNodes)
        let data = mapData(fixture)
        let expected = heading == 90 ? [SplitIntersectionFixture.left, SplitIntersectionFixture.right]
            : [SplitIntersectionFixture.right, SplitIntersectionFixture.left]
        for candidate in data.intersections {
            #expect(data.crossStreetNames(for: candidate, on: SplitIntersectionFixture.main, heading: heading) == expected)
        }
        // Travel east while pointing the phone in either direction.
        let context = DeviceContext(coordinate: heading == 90 ? fixture.roads[0].coordinates[0] : fixture.roads[0].coordinates.last!, headingDegrees: heading,
                                    courseDegrees: 90, courseAccuracy: 5, speedMetersPerSecond: 1.4)
        let service = OrientSvc(locationProvider: FakeLocationProvider(context: context),
                                mapDataClient: StaticMapDataClient(data: data),
                                neighborhoodProvider: FailingNeighborhoodProvider())
        var prefs = AppPrefs()
        prefs.areaMode = .off
        prefs.announcementOptions = AnnouncementOptions(includeDistance: false, includeDirection: false, includeNeighborhood: false)
        let names = ([SplitIntersectionFixture.main] + expected).joined(separator: " and ") + "."
        let nearest = try await service.spokenText(.nearest, prefs: prefs)
        #expect(nearest == "Nearest: " + names)
        let siri = SiriIntersectionRequest { _ in service }
        #expect(try await siri.response(for: .upcoming, prefs: prefs) == "Upcoming: " + names)
        var travelContext = context
        travelContext.headingDegrees = 90
        let live = try await service.liveUpcomingResult(from: travelContext, mapData: data, prefs: prefs,
            preferredRoadName: SplitIntersectionFixture.main, phoneHeading: heading, selectedIntersections: data.intersections)
        #expect(live.text == names)
    }

    @Test func unavailableHeadingKeepsStableNames() {
        let data = mapData(SplitIntersectionFixture(separateNodes: false))
        #expect(data.crossStreetNames(for: data.intersections[0], on: SplitIntersectionFixture.main, heading: nil)
                == [SplitIntersectionFixture.left, SplitIntersectionFixture.right])
    }

    @Test func connectedBranchWinsOverNearbyNamesAndLaterBends() {
        var data = mapData(SplitIntersectionFixture(separateNodes: false))
        let center = SplitIntersectionFixture.center
        // A disconnected same-name road to the south must not change Stanley's side.
        data.roads.insert(MapRoad(id: "unconnected", name: SplitIntersectionFixture.left, nodeIDs: [800, 801], coordinates: [
            CLLocationCoordinate2D(latitude: center.latitude - 0.00001, longitude: center.longitude),
            CLLocationCoordinate2D(latitude: center.latitude - 0.001, longitude: center.longitude)
        ]), at: 0)
        // Stanley later curls close to the south of the junction; its connected
        // segment still leaves the junction toward the north.
        let stanley = data.roads.firstIndex { $0.nodeIDs.contains(1306686148) }!
        data.roads[stanley].nodeIDs.insert(802, at: 0)
        data.roads[stanley].coordinates.insert(
            CLLocationCoordinate2D(latitude: center.latitude - 0.00002, longitude: center.longitude), at: 0)
        for reversed in [false, true] {
            if reversed { data.roads.reverse(); data.intersections[0].names.reverse() }
            #expect(data.crossStreetNames(for: data.intersections[0], on: SplitIntersectionFixture.main, heading: 90)
                    == [SplitIntersectionFixture.left, SplitIntersectionFixture.right])
        }
    }

    private func mapData(_ fixture: SplitIntersectionFixture) -> MapDataSet {
        MapDataSet(intersections: fixture.junctions.map { IntersectionCandidate(id: $0.id, names: $0.names, coordinate: $0.coordinate) },
                   roads: fixture.roads.enumerated().map { index, road in
                       MapRoad(id: String(index), name: road.name, nodeIDs: road.nodes, coordinates: road.coordinates)
                   })
    }
}
