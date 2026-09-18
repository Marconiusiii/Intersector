import CoreLocation
import Foundation

@MainActor
final class SiriIntersectionRequest {
	static let shared = SiriIntersectionRequest()
	private let makeService: @MainActor (Date?) -> OrientSvc
	private let timeout: Duration
	private var refreshNext: Set<ReportKind> = []
	private var attempts: [ReportKind: UUID] = [:]

	init(timeout: Duration = .seconds(20), makeService: @escaping @MainActor (Date?) -> OrientSvc = { minimumDate in
		var client = MapDataClient()
		client.minimumCacheDate = minimumDate
		return OrientSvc(locationProvider: LocationProvider(), mapDataClient: client,
			neighborhoodProvider: NeighborhoodProvider())
	}) {
		self.timeout = timeout
		self.makeService = makeService
	}

	func response(for kind: ReportKind, prefs: AppPrefs) async throws -> String {
		let attempt = UUID()
		attempts[kind] = attempt
		let minimumDate = refreshNext.contains(kind) ? Date() : nil
		let service = makeService(minimumDate)
		do {
			let text = try await LookupAttempt.run(timeout: timeout) {
				try await service.spokenText(kind, prefs: prefs)
			}
			if attempts[kind] == attempt { refreshNext.remove(kind) }
			return text
		} catch {
			try Task.checkCancellation()
			if case OrientError.noIntersections = error, attempts[kind] == attempt {
				// Refresh only on the next explicit invocation, never in an automatic loop.
				refreshNext.insert(kind)
			}
			return Self.failureMessage(error, kind: kind)
		}
	}

	static func failureMessage(_ error: Error, kind: ReportKind) -> String {
		if let urlError = error as? URLError {
			if urlError.code == .timedOut { return "This is taking too long. Please try again." }
			return "I couldn't connect. Check your internet connection and try again."
		}
		if case MapDataError.serversCoolingDown = error {
			return "I can't get intersection information right now. Please wait a minute and try again."
		}
		if case MapDataError.serverError(429) = error {
			return "I can't get intersection information right now. Please wait a minute and try again."
		}
		if case OrientError.headingUnavailable = error {
			return "I couldn't tell which way you're facing. Hold your device steady and try again."
		}
		if case OrientError.locationUnavailable = error {
			return "I couldn't get your location. Please try again."
		}
		if let locationError = error as? CLError {
			return locationError.code == .denied
				? "Allow Intersector to use your location in iPhone Settings, then ask again."
				: "I couldn't get your location. Please try again."
		}
		if case OrientError.noIntersections = error {
			return kind == .upcoming
				? "I couldn't find an intersection ahead. Try facing along the street and ask again."
				: "I couldn't find a nearby intersection. Please try again."
		}
		return "I can't get intersection information right now. Please try again."
	}
}
