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
	private var locationTimeoutTask: Task<Void, Never>?
	private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
	private var headingContinuation: CheckedContinuation<CLLocationDirection, Error>?
	private var headingTimeoutTask: Task<Void, Never>?
	private var latestHeading: CLLocationDirection?
	private var latestHeadingDate: Date?
	private var headingContinuations: [UUID: AsyncStream<CLLocationDirection>.Continuation] = [:]

	override init() {
		super.init()
		manager.delegate = self
		manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
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
			locationTimeoutTask?.cancel()
			locationTimeoutTask = Task { [weak self] in
				try? await Task.sleep(nanoseconds: 4_000_000_000)
				await MainActor.run {
					self?.finish(with: .failure(OrientError.locationUnavailable))
				}
			}
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

	func currentHeading(timeout: TimeInterval = 1.5) async throws -> CLLocationDirection {
		guard CLLocationManager.headingAvailable() else {
			throw OrientError.headingUnavailable
		}

		if let latestHeading,
		   let latestHeadingDate,
		   Date().timeIntervalSince(latestHeadingDate) < 2 {
			return latestHeading
		}

		manager.startUpdatingHeading()
		return try await withCheckedThrowingContinuation { continuation in
			headingContinuation = continuation
			headingTimeoutTask?.cancel()
			headingTimeoutTask = Task { [weak self] in
				let nanoseconds = UInt64(timeout * 1_000_000_000)
				try? await Task.sleep(nanoseconds: nanoseconds)
				await MainActor.run {
					self?.finishHeading(with: .failure(OrientError.headingUnavailable))
				}
			}
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
		locationTimeoutTask?.cancel()
		locationTimeoutTask = nil
		switch result {
		case .success(let context):
			continuation.resume(returning: context)
		case .failure(let error):
			continuation.resume(throwing: error)
		}
	}

	private func finishHeading(with result: Result<CLLocationDirection, Error>) {
		guard let headingContinuation else {
			return
		}
		self.headingContinuation = nil
		headingTimeoutTask?.cancel()
		headingTimeoutTask = nil

		if headingContinuations.isEmpty {
			manager.stopUpdatingHeading()
		}

		switch result {
		case .success(let heading):
			headingContinuation.resume(returning: heading)
		case .failure(let error):
			headingContinuation.resume(throwing: error)
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
			latestHeadingDate = Date()
			finishHeading(with: .success(latestHeading))
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
