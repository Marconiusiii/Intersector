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
	private var backgroundActivitySession: CLBackgroundActivitySession?

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
		return Self.newestUpdateStream { continuation in
			self.updateContinuation?.finish()
			self.updateContinuation = continuation
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.stop()
				}
			}
			self.backgroundActivitySession = CLBackgroundActivitySession()
			self.manager.startUpdatingLocation()
		}
	}

	static func newestUpdateStream(
		_ build: @escaping (AsyncThrowingStream<DeviceContext, Error>.Continuation) -> Void
	) -> AsyncThrowingStream<DeviceContext, Error> {
		AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1), build)
	}

	func stop() {
		manager.stopUpdatingLocation()
		manager.allowsBackgroundLocationUpdates = false
		backgroundActivitySession?.invalidate()
		backgroundActivitySession = nil
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
		manager.allowsBackgroundLocationUpdates = true
		manager.showsBackgroundLocationIndicator = true
		manager.pausesLocationUpdatesAutomatically = false
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
