//
//  LiveLocationProvider.swift
//  Intersector
//

import CoreLocation
import Foundation

@MainActor
final class LiveLocationProvider: NSObject {
	private let manager = CLLocationManager()
	private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
	private var updateContinuation: AsyncThrowingStream<DeviceContext, Error>.Continuation?

	override init() {
		super.init()
		manager.delegate = self
	}

	func updates(for mode: LiveTravelMode) async throws -> AsyncThrowingStream<DeviceContext, Error> {
		let authorization = await authorizationStatus()
		guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
			throw CLError(.denied)
		}

		configure(for: mode)
		return AsyncThrowingStream { continuation in
			updateContinuation?.finish()
			updateContinuation = continuation
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.stop()
				}
			}
			manager.startUpdatingLocation()
		}
	}

	func stop() {
		manager.stopUpdatingLocation()
		updateContinuation = nil
	}

	private func authorizationStatus() async -> CLAuthorizationStatus {
		guard manager.authorizationStatus == .notDetermined else {
			return manager.authorizationStatus
		}
		return await withCheckedContinuation { continuation in
			authorizationContinuation = continuation
			manager.requestWhenInUseAuthorization()
		}
	}

	private func configure(for mode: LiveTravelMode) {
		manager.pausesLocationUpdatesAutomatically = true
		switch mode {
		case .walking:
			manager.activityType = .fitness
			manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
			manager.distanceFilter = 8
		case .driving:
			manager.activityType = .automotiveNavigation
			manager.desiredAccuracy = kCLLocationAccuracyBest
			manager.distanceFilter = 20
		}
	}
}

extension LiveLocationProvider: CLLocationManagerDelegate {
	func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
		guard let authorizationContinuation else {
			return
		}
		self.authorizationContinuation = nil
		authorizationContinuation.resume(returning: manager.authorizationStatus)
	}

	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		for location in locations where
			location.horizontalAccuracy >= 0 &&
			location.horizontalAccuracy <= 100 &&
			abs(location.timestamp.timeIntervalSinceNow) <= 20
		{
			updateContinuation?.yield(
				DeviceContext(
					coordinate: location.coordinate,
					headingDegrees: nil,
					courseDegrees: location.course >= 0 ? location.course : nil,
					courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
					speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
					horizontalAccuracy: location.horizontalAccuracy
				)
			)
		}
	}

	func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		guard (error as? CLError)?.code != .locationUnknown else {
			return
		}
		updateContinuation?.finish(throwing: error)
		stop()
	}
}
