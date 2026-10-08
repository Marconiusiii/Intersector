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
