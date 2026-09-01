//
//  LiveModeCoordinator.swift
//  Intersector
//

import CoreLocation
import Combine
import Foundation

@MainActor
final class LiveModeCoordinator: ObservableObject {
	@Published private(set) var isActive = false
	@Published private(set) var statusText = "Live Mode off."

	private let locationProvider: LiveLocationProvider
	private let mapDataClient: MapDataFetching
	private let reportService: OrientSvc
	private let speechController: SystemSpeechController
	private var locationTask: Task<Void, Never>?
	private var stationaryTask: Task<Void, Never>?
	private var matcher = LiveRoadMatcher()
	private var announcementGate = LiveAnnouncementGate()
	private var movementMonitor = LiveMovementMonitor()
	private var cachedMapData: MapDataSet?
	private var cachedMapCenter: CLLocationCoordinate2D?
	private var cachedMapRadius: CLLocationDistance = 0
	private var cachedMapOptions: MapDetailOptions?
	private var lastMapFetchAt: Date?
	private var activeMode = LiveTravelMode.walking
	private var activePrefs = AppPrefs()
	private var activeSpeechSettings = LiveSpeechSettings(voiceIdentifier: "", ratePercent: 50, volume: 1)
	private var stationaryMinutes = 5.0
	private let minimumMapRefreshInterval: TimeInterval = 3 * 60

	convenience init() {
		self.init(
			locationProvider: LiveLocationProvider(),
			mapDataClient: MapDataClient(),
			reportService: .shared,
			speechController: .shared
		)
	}

	init(
		locationProvider: LiveLocationProvider,
		mapDataClient: MapDataFetching,
		reportService: OrientSvc,
		speechController: SystemSpeechController
	) {
		self.locationProvider = locationProvider
		self.mapDataClient = mapDataClient
		self.reportService = reportService
		self.speechController = speechController
	}

	func start(
		mode: LiveTravelMode,
		prefs: AppPrefs,
		speechSettings: LiveSpeechSettings,
		stationaryMinutes: Double
	) {
		guard !isActive else {
			return
		}
		activeMode = mode
		activePrefs = prefs
		activeSpeechSettings = speechSettings
		self.stationaryMinutes = stationaryMinutes
		matcher.reset()
		announcementGate.reset()
		movementMonitor.reset()
		cachedMapData = nil
		cachedMapCenter = nil
		lastMapFetchAt = nil
		isActive = true
		let message = Self.activationMessage(for: mode)
		statusText = message
		LiveModeEarcon.play(isActive: true, hapticsEnabled: prefs.haptics)
		speechController.speak(message, settings: speechSettings, delay: LiveModeEarcon.speechDelay)

		locationTask = Task { [weak self] in
			guard let self else { return }
			do {
				let updates = try await locationProvider.updates(for: mode)
				for try await context in updates {
					guard !Task.isCancelled, isActive else { return }
					await process(context)
				}
			} catch is CancellationError {
			} catch {
				stop(message: "Live Mode stopped because location is unavailable.")
			}
		}

		stationaryTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(15))
				guard let self, self.isActive else { return }
				if self.movementMonitor.hasTimedOut(after: self.stationaryMinutes) {
					let minutes = Int(self.stationaryMinutes.rounded())
					self.stop(
						message: "Live Mode stopped because you haven't moved for \(minutes) minutes."
					)
					return
				}
			}
		}
	}

	func stop(message: String = "Live Mode off.") {
		guard isActive else {
			statusText = message
			return
		}
		isActive = false
		locationTask?.cancel()
		locationTask = nil
		stationaryTask?.cancel()
		stationaryTask = nil
		locationProvider.stop()
		speechController.stop()
		statusText = message
		LiveModeEarcon.play(isActive: false, hapticsEnabled: activePrefs.haptics)
		speechController.speak(message, settings: activeSpeechSettings, delay: LiveModeEarcon.speechDelay)
	}

	static func activationMessage(for mode: LiveTravelMode) -> String {
		"Live Mode on. \(mode.label)."
	}

	private func process(_ context: DeviceContext) async {
		movementMonitor.record(context)
		do {
			let mapData = try await mapData(for: context)
			guard let match = matcher.match(context, in: mapData, mode: activeMode) else {
				return
			}
			let result = try await reportService.liveUpcomingResult(
				from: match.context,
				mapData: mapData,
				prefs: activePrefs,
				preferredRoadName: match.roadName
			)
			guard announcementGate.shouldAnnounce(
				intersectionID: result.primaryIntersectionID,
				distanceMeters: result.distanceMeters,
				mode: activeMode
			) else {
				return
			}
			statusText = result.text
			speechController.speak(result.text, settings: activeSpeechSettings)
		} catch {
			if cachedMapData == nil {
				statusText = "Live Mode is waiting for map data."
			}
		}
	}

	private func mapData(for context: DeviceContext) async throws -> MapDataSet {
		let now = Date()
		let refreshIsThrottled = lastMapFetchAt.map {
			now.timeIntervalSince($0) < minimumMapRefreshInterval
		} ?? false
		if
			let cachedMapData,
			let cachedMapCenter,
			cachedMapOptions == activePrefs.mapDetails
		{
			let distance = Geo.distanceMeters(from: cachedMapCenter, to: context.coordinate)
			let remainsCovered = distance + 225 <= cachedMapRadius
			if remainsCovered || refreshIsThrottled {
				return cachedMapData
			}
		}
		if cachedMapData == nil, refreshIsThrottled {
			throw URLError(.resourceUnavailable)
		}

		let radius = activeMode.mapRadiusMeters
		lastMapFetchAt = now
		do {
			let data = try await mapDataClient.mapData(
				near: context.coordinate,
				radiusMeters: radius,
				options: activePrefs.mapDetails
			)
			cachedMapData = data
			cachedMapCenter = context.coordinate
			cachedMapRadius = radius
			cachedMapOptions = activePrefs.mapDetails
			return data
		} catch {
			if let cachedMapData {
				return cachedMapData
			}
			throw error
		}
	}
}
