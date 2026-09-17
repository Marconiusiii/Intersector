// Expected outputs are independent fixtures, checked against both production mappings.
@MainActor enum ManhattanChecks {
    static func run() {
        let compass = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let manhattan = ["Uptown", "Uptown", "East Side", "East Side", "Downtown", "Downtown", "West Side", "West Side"]
        var samples = 0
        func check(_ heading: Double, index: Int) {
            for enabled in [false, true] {
                let expected = enabled ? manhattan[index] : compass[index]
                let phone = Geo.localizedDirection(heading, prefs: AppPrefs(manhattanSnobMode: enabled))
                let watch = WatchGeo.localizedDirection(heading, prefs: WatchAppPrefs(manhattanSnobMode: enabled))
                precondition(phone == expected, "Phone: \(heading), enabled \(enabled): \(phone), expected \(expected)")
                precondition(watch == expected, "Watch: \(heading), enabled \(enabled): \(watch), expected \(expected)")
                samples += 1
            }
        }
        for index in 0..<8 {
            check(Double(index) * 45, index: index)
            let boundary = Double(index) * 45 + 22.5
            check(boundary - 0.001, index: index)
            check(boundary, index: (index + 1) % 8)
            check(boundary + 0.001, index: (index + 1) % 8)
            // Intersection announcements translate an existing compass word.
            precondition(WatchGeo.manhattanDirection(for: compass[index]) == manhattan[index])
            precondition(Geo.manhattanDirection(for: compass[index]) == manhattan[index])
        }
        check(-45, index: 7)
        check(360, index: 0)
        check(405, index: 1)
        precondition(WatchGeo.manhattanDirection(for: "unknown") == "unknown")
        print("PASS: \(samples) heading/setting cases match expected phone and Watch wording, including boundaries and wraparound")
        print("PASS: all eight intersection compass words use the same Manhattan mapping")
    }
}
