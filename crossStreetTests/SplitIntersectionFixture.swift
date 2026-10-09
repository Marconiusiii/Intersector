import CoreLocation

// Foothill/Stanley/Talbot geometry from OpenStreetMap, retrieved 2026-10-09.
// Both cross streets meet Foothill at node 53021961. The separate-node variant
// exercises the other supported representation of a staggered intersection.
struct SplitIntersectionFixture {
    struct Junction {
        var id: String
        var names: [String]
        var coordinate: CLLocationCoordinate2D
    }
    struct Road {
        var name: String
        var nodes: [Int64]
        var coordinates: [CLLocationCoordinate2D]
    }
    static let main = "Foothill Boulevard"
    static let left = "Stanley Avenue"
    static let right = "Talbot Avenue"
    static let center = CLLocationCoordinate2D(latitude: 37.7450446, longitude: -122.1502054)
    var junctions: [Junction]
    var roads: [Road]

    init(separateNodes: Bool) {
        let talbot = separateNodes
            ? CLLocationCoordinate2D(latitude: Self.center.latitude, longitude: Self.center.longitude + 0.0001)
            : Self.center
        let talbotID: Int64 = separateNodes ? 999 : 53021961
        junctions = separateNodes ? [
            Junction(id: "53021961", names: [Self.main, Self.left], coordinate: Self.center),
            Junction(id: "999", names: [Self.main, Self.right], coordinate: talbot)
        ] : [Junction(id: "53021961", names: [Self.main, Self.left, Self.right], coordinate: Self.center)]
        roads = [
            Road(name: Self.main, nodes: separateNodes ? [1306686036, 53021961, talbotID, 1306686110] : [1306686036, 53021961, 1306686110], coordinates: [
                CLLocationCoordinate2D(latitude: 37.7450526, longitude: -122.1502689),
                Self.center
            ] + (separateNodes ? [talbot] : []) + [
                separateNodes ? CLLocationCoordinate2D(latitude: Self.center.latitude, longitude: Self.center.longitude + 0.0003)
                    : CLLocationCoordinate2D(latitude: 37.7450258, longitude: -122.1501571)
            ]),
            Road(name: Self.left, nodes: [1306686174, 1306686148, 53021961], coordinates: [
                CLLocationCoordinate2D(latitude: 37.7451287, longitude: -122.1501213),
                CLLocationCoordinate2D(latitude: 37.7450865, longitude: -122.1501562), Self.center
            ]),
            Road(name: Self.right, nodes: [6422051805, 6422051804, talbotID], coordinates: [
                CLLocationCoordinate2D(latitude: 37.7449505, longitude: -122.1503586),
                CLLocationCoordinate2D(latitude: 37.7449648, longitude: -122.1503354), talbot
            ])
        ]
    }
}
