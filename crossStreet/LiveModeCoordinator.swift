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

	private let locationProvider: any LiveLocationProviding
	private let mapDataClient: MapDataFetching
	private let reportService: OrientSvc
	private let speechController: any LiveSpeaking
	private var locationTask: Task<Void, Never>?
	private var processingTask: Task<Void, Never>?
	private var pendingContext: (DeviceContext, Date)?
	private var sessionID = UUID()
	private var processingID = UUID()
	private var highwayDetector = LiveHighwayDetector()
	private var lastLocationAt = Date()
	private var lastFetchFailed = false
	private let now: () -> Date
	private let playsFeedback: Bool
	private var stationaryTask: Task<Void, Never>?
	private var matcher = LiveRoadMatcher()
	private var announcementGate = LiveAnnouncementGate()
	private var movementMonitor = LiveMovementMonitor()
	private var cachedMapData: MapDataSet?
	private var cachedMapCenter: CLLocationCoordinate2D?
	private var cachedMapRadius: CLLocationDistance = 0
	private var cachedMapOptions: MapDetailOptions?
	private var lastMapFetchAt: Date?
	private var lastMapFetchOptions: MapDetailOptions?
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
			speechController: SystemSpeechController.shared
		)
	}

	init(
		locationProvider: any LiveLocationProviding,
		mapDataClient: MapDataFetching,
		reportService: OrientSvc,
		speechController: any LiveSpeaking,
		now: @escaping () -> Date = Date.init,
		playsFeedback: Bool = true
	) {
		self.locationProvider = locationProvider
		self.mapDataClient = mapDataClient
		self.reportService = reportService
		self.speechController = speechController
		self.now = now
		self.playsFeedback = playsFeedback
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
		sessionID = UUID()
		let session = sessionID
		processingID = UUID()
		highwayDetector.reset()
		lastLocationAt = now()
		lastFetchFailed = false
		activeMode = mode
		activePrefs = prefs
		activeSpeechSettings = speechSettings
		self.stationaryMinutes = stationaryMinutes
		matcher.reset()
		announcementGate.reset()
		movementMonitor.reset(at: now())
		cachedMapData = nil
		cachedMapCenter = nil
		lastMapFetchAt = nil
		lastMapFetchOptions = nil
		isActive = true
		let message = Self.activationMessage(for: mode)
		statusText = message
		if playsFeedback { LiveModeEarcon.play(isActive: true, hapticsEnabled: prefs.haptics) }
		speechController.speak(message, settings: speechSettings, delay: LiveModeEarcon.speechDelay)

		locationTask = Task { [weak self] in
			guard let self else { return }
			do {
				guard !Task.isCancelled, isActive, sessionID == session else { return }
				let updates = try await locationProvider.updates(for: activeMode)
				for try await context in updates {
					guard !Task.isCancelled, isActive, sessionID == session else { return }
					receive(context)
				}
				guard !Task.isCancelled, sessionID == session, isActive else { return }
				stop(message: "Live Mode stopped because location updates ended.")
			} catch is CancellationError {
			} catch {
				guard !Task.isCancelled, sessionID == session, isActive else { return }
				stop(message: "Live Mode stopped because location is unavailable.")
			}
		}

		stationaryTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .seconds(15))
				guard !Task.isCancelled, let self, self.isActive, self.sessionID == session else { return }
				if self.checkTimeouts() {
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
		sessionID = UUID()
		processingID = UUID()
		processingTask?.cancel()
		processingTask = nil
		pendingContext = nil
		locationTask?.cancel()
		locationTask = nil
		stationaryTask?.cancel()
		stationaryTask = nil
		locationProvider.stop()
		speechController.stop()
		statusText = message
		if playsFeedback { LiveModeEarcon.play(isActive: false, hapticsEnabled: activePrefs.haptics) }
		speechController.speak(message, settings: activeSpeechSettings, delay: LiveModeEarcon.speechDelay)
	}

	static func activationMessage(for mode: LiveTravelMode) -> String {
		"Live Mode on. \(mode.label)."
	}

	func switchMode(to mode: LiveTravelMode) {
		guard isActive else { return }
		guard activeMode != mode else {
			speechController.speak("\(mode.label) already selected.", settings: activeSpeechSettings, delay: 0)
			return
		}
		activeMode = mode
		locationProvider.updateMode(mode)
		processingID = UUID()
		processingTask?.cancel()
		processingTask = nil
		pendingContext = nil
		matcher.reset()
		highwayDetector.reset()
		announcementGate.reset()
		let message = "Live Mode switched to \(mode.label)."
		statusText = message
		speechController.speak(message, settings: activeSpeechSettings, delay: 0)
	}

	private var mapOptions: MapDetailOptions {
		var options = activePrefs.mapDetails
		options.includeHighways = activeMode == .driving
		return options
	}

	private func receive(_ context: DeviceContext) {
		let now = now()
		lastLocationAt = now
		movementMonitor.record(context, at: now)
		if stopIfStationary() { return }
		pendingContext = (context, now)
		guard processingTask == nil else { return }
		let operation = processingID
		processingTask = Task { [weak self] in
			guard let self else { return }
			while !Task.isCancelled, isActive, processingID == operation, let pending = pendingContext {
				pendingContext = nil
				await process(pending.0, receivedAt: pending.1, operation: operation)
			}
			if processingID == operation { processingTask = nil }
		}
	}

	private func process(_ context: DeviceContext, receivedAt: Date, operation: UUID) async {
		do {
			let mapData = try await mapData(for: context)
			guard !Task.isCancelled, isActive, processingID == operation else { return }
			// Prefer the newest position after a slow fetch; never report a passed location.
			guard pendingContext == nil, now().timeIntervalSince(receivedAt) <= 10 else { return }
			if activeMode == .driving,
			   let highway = highwayDetector.highwayEntered(in: mapData, context: context, now: now()) {
				stop(message: LiveHighwayDetector.shutdownMessage(for: highway))
				return
			}
			guard let match = matcher.match(context, in: mapData, mode: activeMode) else { return }
			let result = try await reportService.liveUpcomingResult(
				from: match.context, mapData: mapData, prefs: activePrefs, preferredRoadName: match.roadName
			)
			guard !Task.isCancelled, isActive, processingID == operation,
				  pendingContext == nil, now().timeIntervalSince(receivedAt) <= 10 else { return }
			guard announcementGate.shouldAnnounce(
				intersectionID: result.primaryIntersectionID,
				distanceMeters: result.distanceMeters, mode: activeMode, now: now()
			) else { return }
			statusText = result.text
			speechController.speak(result.text, settings: activeSpeechSettings, delay: 0)
		} catch {
			guard !Task.isCancelled, isActive, processingID == operation else { return }
			if cachedMapData == nil { statusText = "Live Mode is waiting for map data." }
		}
	}

	@discardableResult
	func checkTimeouts() -> Bool {
		guard isActive else { return false }
		return stopIfLocationUnavailable() || stopIfStationary()
	}

	@discardableResult
	private func stopIfLocationUnavailable() -> Bool {
		guard now().timeIntervalSince(lastLocationAt) >= max(120, stationaryMinutes * 60) else { return false }
		stop(message: "Live Mode stopped because no recent location updates are available.")
		return true
	}

	@discardableResult
	private func stopIfStationary() -> Bool {
		guard movementMonitor.hasTimedOut(after: stationaryMinutes, at: now()) else {
			return false
		}
		let minutes = Int(stationaryMinutes.rounded())
		let duration = minutes == 1 ? "1 minute" : "\(minutes) minutes"
		stop(message: "Live Mode stopped because you haven't moved for \(duration).")
		return true
	}

	private func mapData(for context: DeviceContext) async throws -> MapDataSet {
		let now = now()
		let operation = processingID
		let options = mapOptions
		let refreshInterval = activeMode == .driving && !lastFetchFailed ? 60.0 : minimumMapRefreshInterval
		let refreshIsThrottled = lastMapFetchAt.map {
			now.timeIntervalSince($0) < refreshInterval
		} ?? false
		if
			let cachedMapData,
			let cachedMapCenter,
			cachedMapOptions == options
		{
			let distance = Geo.distanceMeters(from: cachedMapCenter, to: context.coordinate)
			let remainsCovered = distance + 225 <= cachedMapRadius
			if remainsCovered || refreshIsThrottled {
				return cachedMapData
			}
		}
		if refreshIsThrottled, lastMapFetchOptions == options {
			if let cachedMapData { return cachedMapData }
			throw URLError(.resourceUnavailable)
		}

		let radius = activeMode.mapRadiusMeters
		lastMapFetchAt = now
		lastMapFetchOptions = options
		do {
			let data = try await mapDataClient.freshMapData(
				near: context.coordinate,
				radiusMeters: radius,
				options: options
			)
			try Task.checkCancellation()
			guard isActive, processingID == operation else { throw CancellationError() }
			lastFetchFailed = false
			cachedMapData = data
			cachedMapCenter = context.coordinate
			cachedMapRadius = radius
			cachedMapOptions = options
			return data
		} catch {
			guard !Task.isCancelled, isActive, processingID == operation else { throw CancellationError() }
			lastFetchFailed = true
			if let cachedMapData {
				return cachedMapData
			}
			throw error
		}
	}
}
