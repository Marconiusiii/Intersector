import Foundation

// The Watch command-line checks decode the same fixtures and expected results.
struct CrossingFixtures<Response: Decodable>: Decodable {
    let cases: [CrossingFixture<Response>]
}

struct CrossingFixture<Response: Decodable>: Decodable {
    let name: String
    let response: Response
    let expected: [ExpectedCrossing]
    let bounds: [Double]?
    let roadFilter: String?

    func includes(latitude: Double, longitude: Double, roads: [String]) -> Bool {
        if let roadFilter, !roads.contains(roadFilter) { return false }
        guard let bounds else { return true }
        return latitude >= bounds[0] && longitude >= bounds[1] && latitude <= bounds[2] && longitude <= bounds[3]
    }
}

struct ExpectedCrossing: Decodable {
    let id: String
    let lat: Double
    let lon: Double
    let road: String
    let signal: Bool
}

// Small constructed cases run through both production parsers and report formatters.
struct IntersectionDetailFixture {
    let name: String
    var nodeTags: [String: String] = ["highway": "crossing"]
    var pathTags: [[String: String]] = []
    var streetIntersection = false
    var nearbyOnly = false
    let phrases: [String]

    var candidateID: String { nearbyOnly ? "6" : (streetIntersection ? "2" : "crossing-2") }

    func responseData(reversePaths: Bool = false) throws -> Data {
        var elements: [[String: Any]] = [
            ["type": "node", "id": 1, "lat": 39.999, "lon": -74.0],
            ["type": "node", "id": 2, "lat": 40.0, "lon": -74.0, "tags": nodeTags],
            ["type": "node", "id": 3, "lat": 40.001, "lon": -74.0],
            ["type": "node", "id": 4, "lat": 40.0, "lon": -74.001],
            ["type": "node", "id": 5, "lat": 40.0, "lon": -73.999],
            ["type": "node", "id": 6, "lat": 40.0001, "lon": -74.0],
            ["type": "node", "id": 7, "lat": 40.0, "lon": -74.0001],
            ["type": "node", "id": 8, "lat": 40.0, "lon": -73.9999],
            ["type": "way", "id": 10, "nodes": nearbyOnly ? [1, 2, 6, 3] : [1, 2, 3],
             "tags": ["highway": "residential", "name": "Main Street"]]
        ]
        if streetIntersection || nearbyOnly {
            elements.append(["type": "way", "id": 11, "nodes": [4, nearbyOnly ? 6 : 2, 5],
                             "tags": ["highway": "residential", "name": "Oak Street"]])
        }
        let paths = reversePaths ? Array(pathTags.reversed()) : pathTags
        for (index, tags) in paths.enumerated() {
            elements.append(["type": "way", "id": 20 + index, "nodes": [7, 2, 8],
                             "tags": tags.merging(["highway": "footway", "footway": "crossing"]) { _, value in value }])
        }
        return try JSONSerialization.data(withJSONObject: ["elements": elements])
    }

    static let cases: [Self] = [
        .init(name: "signalized crossing", nodeTags: ["highway": "crossing", "crossing": "traffic_signals"], phrases: ["signalized crossing"]),
        .init(name: "sound tags do not establish signal details", nodeTags: ["highway": "crossing", "traffic_signals:sound": "yes"], phrases: []),
        .init(name: "sound tags do not replace signal details", nodeTags: ["highway": "crossing", "crossing:signals": "yes", "traffic_signals:sound": "walk"], phrases: ["signalized crossing"]),
        .init(name: "missing details stay silent", phrases: []),
        .init(name: "signal and island", nodeTags: ["highway": "crossing", "crossing:signals": "yes", "crossing:island": "yes"], phrases: ["signalized crossing", "pedestrian island"]),
        .init(name: "legacy signal conflicts with explicit no", nodeTags: ["highway": "crossing", "crossing": "traffic_signals", "crossing:signals": "no"], phrases: []),
        .init(name: "legacy island conflicts with explicit no", nodeTags: ["highway": "crossing", "crossing": "island", "crossing:island": "no"], phrases: []),
        .init(name: "separate island is not inferred", nodeTags: ["highway": "crossing", "crossing:island": "separate"], phrases: []),
        .init(name: "negative signal path remains evidence", nodeTags: ["highway": "crossing", "crossing:signals": "yes"], pathTags: [["crossing:signals": "no"]], phrases: []),
        .init(name: "path signal conflict is order independent", nodeTags: [:], pathTags: [["crossing": "traffic_signals"], ["crossing:signals": "no"]], phrases: []),
        .init(name: "path island conflict is omitted", nodeTags: ["highway": "crossing", "crossing:island": "yes"], pathTags: [["crossing:island": "no"]], phrases: []),
        .init(name: "intersection signal at shared node", nodeTags: ["highway": "traffic_signals"], streetIntersection: true, phrases: ["signalized intersection"]),
        .init(name: "intersection signal and island at shared node", nodeTags: ["highway": "crossing", "crossing:signals": "yes", "crossing:island": "yes"], streetIntersection: true, phrases: ["signalized intersection", "pedestrian island"]),
        .init(name: "crossing path enriches exact intersection node", nodeTags: [:], pathTags: [["crossing": "traffic_signals"]], streetIntersection: true, phrases: ["signalized intersection"]),
        .init(name: "nearby suppressed crossing does not enrich intersection", nodeTags: ["highway": "crossing", "crossing:signals": "yes", "crossing:island": "yes"], nearbyOnly: true, phrases: []),
        .init(name: "blinking vehicle signal omitted", nodeTags: ["highway": "traffic_signals", "traffic_signals": "blinker"], streetIntersection: true, phrases: [])
    ]
}
