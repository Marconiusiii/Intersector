//
//  LiveLocationProvider.swift
//  Intersector
//

import CoreLocation
import Foundation

@MainActor
protocol LiveLocationProviding: AnyObject {
	func updates(for mode: LiveTravelMode) async throws -> AsyncThrowingStream<DeviceContext, Error>
	func updateMode(_ mode: LiveTravelMode)
	func stop()
}

@MainActor
final class LiveLocationProvider: NSObject, LiveLocationProviding {
	private let manager = CLLocationManager()
	private var sessionID = UUID()
	private var requestedMode = LiveTravelMode.walking
	private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
	private var updateContinuation: AsyncThrowingStream<DeviceContext, Error>.Continuation?
	private var backgroundActivitySession: CLBackgroundActivitySession?

	override init() {
		super.init()
		manager.delegate = self
	}

	func updates(for mode: LiveTravelMode) async throws -> AsyncThrowingStream<DeviceContext, Error> {
		stop()
		let session = sessionID
		requestedMode = mode
		let authorization = await authorizationStatus()
		try Task.checkCancellation()
		guard session == sessionID else { throw CancellationError() }
		guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
			throw CLError(.denied)
		}

		configure(for: requestedMode)
		return Self.newestUpdateStream { continuation in
			self.updateContinuation?.finish()
			self.updateContinuation = continuation
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor [weak self] in
					guard let self, self.sessionID == session else { return }
					self.stop()
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

	func updateMode(_ mode: LiveTravelMode) {
		requestedMode = mode
		if updateContinuation != nil { configure(for: mode) }
	}

	func stop() {
		sessionID = UUID()
		let authorization = authorizationContinuation
		authorizationContinuation = nil
		authorization?.resume(returning: manager.authorizationStatus)
		let continuation = updateContinuation
		updateContinuation = nil
		continuation?.finish()
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
		for location in locations {
			let context = DeviceContext(
				coordinate: location.coordinate,
				headingDegrees: nil,
				courseDegrees: location.course >= 0 ? location.course : nil,
				courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
				speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
				horizontalAccuracy: location.horizontalAccuracy,
				measuredAt: location.timestamp,
				speedAccuracyMetersPerSecond: location.speedAccuracy
			)
			if requestedMode == .walking {
				guard WalkingLiveTracker.accepts(context, at: .now) else { continue }
			} else {
				guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
					abs(location.timestamp.timeIntervalSinceNow) <= 20 else { continue }
			}
			updateContinuation?.yield(context)
		}
	}

	static func isRecoverable(_ error: Error) -> Bool {
		guard let code = (error as? CLError)?.code else { return false }
		return code == .locationUnknown || code == .network
	}

	func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		guard !Self.isRecoverable(error) else {
			return
		}
		updateContinuation?.finish(throwing: error)
		stop()
	}
}
