import Foundation

// Sensor doubles for running the unchanged production acquisition class without hardware.
typealias CLLocationDirection = Double
typealias CLLocationSpeed = Double
typealias CLLocationAccuracy = Double
let kCLLocationAccuracyBest = 1.0
let kCLDistanceFilterNone = -1.0
struct CLLocationCoordinate2D { var latitude = 37.0; var longitude = -122.0 }
enum CLAuthorizationStatus { case notDetermined, authorizedAlways, authorizedWhenInUse, denied, restricted }
enum WatchReportError: Error { case locationUnavailable, headingUnavailable }
struct CLLocation {
    var coordinate = CLLocationCoordinate2D()
    var course = -1.0
    var courseAccuracy = -1.0
    var speed = 0.0
    var horizontalAccuracy = 5.0
}
struct CLHeading {
    var headingAccuracy = 1.0
    var trueHeading = 90.0
    var magneticHeading = 90.0
}
@MainActor protocol CLLocationManagerDelegate: AnyObject {}
final class CLLocationManager {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus = CLAuthorizationStatus.authorizedWhenInUse
    var desiredAccuracy = 0.0
    var distanceFilter = 0.0
    var headingFilter = 0.0
    var locationRunning = false
    var headingRunning = false
    static func headingAvailable() -> Bool { true }
    func startUpdatingLocation() { locationRunning = true }
    func stopUpdatingLocation() { locationRunning = false }
    func startUpdatingHeading() { headingRunning = true }
    func stopUpdatingHeading() { headingRunning = false }
    func requestWhenInUseAuthorization() {}
}

@main struct Checks {
    @MainActor static func pause(_ milliseconds: Int = 20) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
    @MainActor static func expectStopped(_ manager: CLLocationManager) {
        precondition(!manager.locationRunning && !manager.headingRunning, "Sensors must stop")
    }
    @MainActor static func main() async throws {
        ManhattanChecks.run()
        // Location first: the result must wait for fresh heading, but GPS can stop immediately.
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager)
            var finished = false
            let request = Task { let value = try await provider.currentContext(requiresFreshHeading: true); finished = true; return value }
            await pause()
            precondition(manager.locationRunning && manager.headingRunning, "Both requests must start together")
            provider.locationManager(manager, didUpdateLocations: [CLLocation()])
            await pause()
            precondition(!finished && !manager.locationRunning && manager.headingRunning)
            provider.locationManager(manager, didUpdateHeading: CLHeading())
            let value = try await request.value
            precondition(value.headingDegrees == 90)
            expectStopped(manager)
            print("PASS: location first waits for fresh heading and stops sensors")
        }
        // Heading first: no result until a location arrives.
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager)
            var finished = false
            let request = Task { let value = try await provider.currentContext(requiresFreshHeading: true); finished = true; return value }
            await pause()
            provider.locationManager(manager, didUpdateHeading: CLHeading(trueHeading: 180))
            await pause(300)
            precondition(!finished && manager.locationRunning)
            provider.locationManager(manager, didUpdateLocations: [CLLocation()])
            let value = try await request.value
            precondition(value.headingDegrees == 180)
            expectStopped(manager)
            print("PASS: heading first waits for location")
        }
        // Missing compass retains the existing optional-heading fallback.
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager, headingAvailable: { false })
            let request = Task { try await provider.currentContext(requiresFreshHeading: true) }
            await pause()
            provider.locationManager(manager, didUpdateLocations: [CLLocation()])
            let value = try await request.value
            precondition(value.headingDegrees == nil)
            expectStopped(manager)
            print("PASS: unavailable compass returns location without inventing heading")
        }
        // Heading timeout must release a location that already arrived.
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager)
            let request = Task { try await provider.currentContext(requiresFreshHeading: true) }
            await pause()
            provider.locationManager(manager, didUpdateLocations: [CLLocation()])
            let value = try await request.value
            precondition(value.headingDegrees == nil)
            expectStopped(manager)
            print("PASS: heading timeout preserves fallback and releases sensors")
        }
        // Cancel while a heading settling callback is pending, then reuse the provider.
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager)
            let request = Task { try await provider.currentContext(requiresFreshHeading: true) }
            await pause()
            provider.locationManager(manager, didUpdateHeading: CLHeading())
            request.cancel()
            do { _ = try await request.value; preconditionFailure("Cancellation should fail") } catch is CancellationError {} 
            expectStopped(manager)
            let retry = Task { try await provider.currentContext(requiresFreshHeading: true) }
            await pause()
            provider.locationManager(manager, didUpdateHeading: CLHeading(trueHeading: 270))
            provider.locationManager(manager, didUpdateLocations: [CLLocation()])
            let value = try await retry.value
            precondition(value.headingDegrees == 270)
            expectStopped(manager)
            print("PASS: cancellation and immediate retry do not leak stale callbacks")
        }
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager)
            let request = Task { try await provider.currentContext(requiresFreshHeading: true) }
            await pause()
            provider.locationManager(manager, didFailWithError: WatchReportError.locationUnavailable)
            do { _ = try await request.value; preconditionFailure("Location failure should fail") } catch {}
            await pause(300)
            expectStopped(manager)
            print("PASS: location failure cancels heading work")
        }
        do {
            let manager = CLLocationManager()
            manager.authorizationStatus = .notDetermined
            let provider = WatchLocationProvider(manager: manager)
            let request = Task { try await provider.currentContext(requiresFreshHeading: true) }
            await pause()
            request.cancel()
            do { _ = try await request.value; preconditionFailure("Authorization cancellation should finish") } catch {}
            expectStopped(manager)
            print("PASS: cancellation while awaiting permission completes")
        }
        do {
            let manager = CLLocationManager()
            let provider = WatchLocationProvider(manager: manager)
            let request = Task { try await provider.currentContext(requiresFreshHeading: true) }
            do { _ = try await request.value; preconditionFailure("Missing location must time out") } catch {}
            expectStopped(manager)
            print("PASS: location timeout releases both sensors")
        }
        print("All 8 Watch acquisition checks passed.")
    }
}
