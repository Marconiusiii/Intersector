//
//  PointScanController.swift
//  crossStreet
//
//  Created by Marco Salsiccia on 6/7/26.
//

import Combine
import CoreLocation
import Foundation

@MainActor
final class PointScanController: ObservableObject {
	@Published private(set) var isPreparing = false
	@Published private(set) var isScanning = false

	private let locationProvider = LocationProvider()
	private let mapDataClient = MapDataClient()
	private let finder = IntersectionFinder()
	private let haptics = HapticFeedback()
	private var scanTask: Task<Void, Never>?
	private var lastPulse = Date.distantPast
	private var spokenCooldowns: [String: Date] = [:]

	func setScanning(
		_ enabled: Bool,
		prefs: AppPrefs,
		onUpdate: @escaping (String) -> Void
	) {
		if enabled {
			start(prefs: prefs, onUpdate: onUpdate)
		} else {
			stop()
		}
	}

	private func start(
		prefs: AppPrefs,
		onUpdate: @escaping (String) -> Void
	) {
		guard scanTask == nil else {
			return
		}

		isPreparing = true

		scanTask = Task { [weak self] in
			guard let self else {
				return
			}

			do {
				let initialContext = try await locationProvider.currentContext()
				let mapData = try await mapDataClient.mapData(
					near: initialContext.coordinate,
					radiusMeters: 450
				)
				let intersections = mapData.currentStreetIntersections(
					from: initialContext.coordinate
				)

				guard !intersections.isEmpty else {
					throw OrientError.noIntersections
				}

				isPreparing = false
				isScanning = true

				for await heading in locationProvider.headingUpdates() {
					guard !Task.isCancelled else {
						return
					}
					let context = DeviceContext(
						coordinate: initialContext.coordinate,
						headingDegrees: heading
					)
					handleHeading(
						context,
						intersections: intersections,
						prefs: prefs,
						onUpdate: onUpdate
					)
				}
			} catch {
				isPreparing = false
				isScanning = false
				scanTask = nil
				let text = "Unable to start Point and Scan. \(error.localizedDescription)"
				onUpdate(text)
				VoiceOverAnnouncer.reportUpdated(text)
			}
		}
	}

	private func stop() {
		scanTask?.cancel()
		scanTask = nil
		isPreparing = false
		isScanning = false
	}

	private func handleHeading(
		_ context: DeviceContext,
		intersections: [IntersectionCandidate],
		prefs: AppPrefs,
		onUpdate: @escaping (String) -> Void
	) {
		guard let match = finder.scanMatch(from: context, in: intersections) else {
			return
		}

		let pulseWindow = 45.0
		if prefs.haptics, match.angleDelta <= pulseWindow {
			let intensity = 1.0 - (match.angleDelta / pulseWindow)
			pulseIfNeeded(intensity: intensity)
		}

		guard match.angleDelta <= 8, canAnnounce(match.candidate.id) else {
			return
		}

		let report = OrientReport(
			kind: .scan,
			cross: match.candidate.title,
			dist: Geo.spokenDistance(match.distanceMeters),
			relDir: "where the phone is pointing",
			street: match.candidate.names.first,
			head: Geo.compassDirection(match.bearingDegrees),
			area: nil,
			toward: nil,
			conf: .high
		)
		let text = report.text(with: prefs)
		spokenCooldowns[match.candidate.id] = Date()
		onUpdate(text)
		if prefs.haptics {
			haptics.identify()
		}
		VoiceOverAnnouncer.reportUpdated(text)
	}

	private func pulseIfNeeded(intensity: Double) {
		let now = Date()
		guard now.timeIntervalSince(lastPulse) >= 0.18 else {
			return
		}
		lastPulse = now
		haptics.pulse(intensity: intensity)
	}

	private func canAnnounce(_ id: String) -> Bool {
		guard let lastSpoken = spokenCooldowns[id] else {
			return true
		}
		return Date().timeIntervalSince(lastSpoken) >= 8
	}
}
