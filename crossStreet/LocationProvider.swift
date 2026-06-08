//
//  LocationProvider.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import CoreLocation
import Foundation

@MainActor
final class LocationProvider: NSObject, LocationProviding {
	private let manager = CLLocationManager()
	private var continuation: CheckedContinuation<DeviceContext, Error>?
	private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
	private var latestHeading: CLLocationDirection?
	private var headingContinuations: [UUID: AsyncStream<CLLocationDirection>.Continuation] = [:]

	override init() {
		super.init()
		manager.delegate = self
		manager.desiredAccuracy = kCLLocationAccuracyBest
		manager.headingFilter = 5
	}

	func currentContext() async throws -> DeviceContext {
		if CLLocationManager.headingAvailable() {
			manager.startUpdatingHeading()
		}

		switch manager.authorizationStatus {
		case .notDetermined:
			let status = await requestWhenInUseAuthorization()
			guard status == .authorizedAlways || status == .authorizedWhenInUse else {
				throw CLError(.denied)
			}
		case .authorizedAlways, .authorizedWhenInUse:
			break
		case .denied, .restricted:
			throw CLError(.denied)
		@unknown default:
			throw CLError(.denied)
		}

		return try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			manager.requestLocation()
		}
	}

	func requestWhenInUseAuthorization() async -> CLAuthorizationStatus {
		switch manager.authorizationStatus {
		case .notDetermined:
			return await withCheckedContinuation { continuation in
				authorizationContinuation = continuation
				manager.requestWhenInUseAuthorization()
			}
		default:
			return manager.authorizationStatus
		}
	}

	func headingUpdates() -> AsyncStream<CLLocationDirection> {
		if CLLocationManager.headingAvailable() {
			manager.startUpdatingHeading()
		}

		return AsyncStream { continuation in
			let id = UUID()
			headingContinuations[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { @MainActor [weak self] in
					self?.headingContinuations[id] = nil
					if self?.headingContinuations.isEmpty == true {
						self?.manager.stopUpdatingHeading()
					}
				}
			}
		}
	}

	private func finish(with result: Result<DeviceContext, Error>) {
		guard let continuation else {
			return
		}
		self.continuation = nil
		switch result {
		case .success(let context):
			continuation.resume(returning: context)
		case .failure(let error):
			continuation.resume(throwing: error)
		}
	}
}

extension LocationProvider: CLLocationManagerDelegate {
	func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
		if let authorizationContinuation {
			self.authorizationContinuation = nil
			authorizationContinuation.resume(returning: manager.authorizationStatus)
		}

		switch manager.authorizationStatus {
		case .authorizedAlways, .authorizedWhenInUse:
			if continuation != nil {
				manager.requestLocation()
			}
		case .denied, .restricted:
			finish(with: .failure(CLError(.denied)))
		default:
			break
		}
	}

	func locationManager(
		_ manager: CLLocationManager,
		didUpdateLocations locations: [CLLocation]
	) {
		guard let location = locations.last else {
			finish(with: .failure(CLError(.locationUnknown)))
			return
		}

		finish(
			with: .success(
				DeviceContext(
					coordinate: location.coordinate,
					headingDegrees: latestHeading
				)
			)
		)
	}

	func locationManager(
		_ manager: CLLocationManager,
		didUpdateHeading newHeading: CLHeading
	) {
		let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
		latestHeading = heading >= 0 ? heading : nil
		if let latestHeading {
			for continuation in headingContinuations.values {
				continuation.yield(latestHeading)
			}
		}
	}

	func locationManager(
		_ manager: CLLocationManager,
		didFailWithError error: Error
	) {
		finish(with: .failure(error))
	}
}
