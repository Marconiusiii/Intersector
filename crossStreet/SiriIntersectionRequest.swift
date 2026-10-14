import CoreLocation
import Foundation

@MainActor
final class SiriIntersectionRequest {
	static let shared = SiriIntersectionRequest()
	private let makeService: @MainActor (Date?) -> OrientSvc
	private let timeout: Duration
	private var refreshNext: Set<ReportKind> = []
	private var attempts: [ReportKind: UUID] = [:]

	init(timeout: Duration = LookupDeadline.requestTimeout, makeService: @escaping @MainActor (Date?) -> OrientSvc = { minimumDate in
		var client = MapDataClient()
		client.minimumCacheDate = minimumDate
		return OrientSvc(locationProvider: LocationProvider(), mapDataClient: client,
			neighborhoodProvider: NeighborhoodProvider())
	}) {
		self.timeout = timeout
		self.makeService = makeService
	}

	func response(for kind: ReportKind, prefs: AppPrefs) async throws -> String {
		do {
			return try await perform(kind: kind) { service in try await service.spokenText(kind, prefs: prefs) }
		} catch {
			try Task.checkCancellation()
			LookupDiagnostics.event("Siri response", detail: "failure dialog; \(LookupDiagnostics.failureCode(error))")
			return Self.failureMessage(error, kind: kind)
		}
	}

	func report(for kind: ReportKind, rank: Int = 1, prefs: AppPrefs) async throws -> OrientReport {
		try await perform(kind: kind, rank: rank) { service in try await service.report(kind, rank: rank, prefs: prefs) }
	}

	private func perform<Value: Sendable>(kind: ReportKind, rank: Int = 1, operation: @escaping @MainActor @Sendable (OrientSvc) async throws -> Value) async throws -> Value {
		let attempt = UUID()
		attempts[kind] = attempt
		LookupDiagnostics.event("Siri request", id: attempt.uuidString, detail: "kind=\(kind); rank=\(rank); started")
		defer { LookupDiagnostics.event("Siri request", id: attempt.uuidString, detail: "kind=\(kind); exited; cancelled=\(Task.isCancelled)") }
		let service = makeService(refreshNext.contains(kind) ? Date() : nil)
		do {
			let value = try await LookupAttempt.run(timeout: timeout, stage: "Siri intersection") {
				try await operation(service)
			}
			if attempts[kind] == attempt { refreshNext.remove(kind) }
			return value
		} catch {
			try Task.checkCancellation()
			if case OrientError.noIntersections = error, attempts[kind] == attempt { refreshNext.insert(kind) }
			throw error
		}
	}

	static func failureMessage(_ error: Error, kind: ReportKind, rank: Int = 1) -> String {
		if let urlError = error as? URLError {
			if urlError.code == .timedOut { return L10n.text("This is taking too long. Please try again.") }
			return L10n.text("I couldn't connect. Check your internet connection and try again.")
		}
		if case MapDataError.serversCoolingDown = error {
			return L10n.text("I can't get intersection information right now. Please wait a minute and try again.")
		}
		if case MapDataError.serverError(429) = error {
			return L10n.text("I can't get intersection information right now. Please wait a minute and try again.")
		}
		if case OrientError.headingUnavailable = error {
			return L10n.text("I couldn't tell which way you're facing. Hold your device steady and try again.")
		}
		if case OrientError.locationUnavailable = error {
			return L10n.text("I couldn't get your location. Please try again.")
		}
		if let locationError = error as? CLError {
			return locationError.code == .denied
				? L10n.text("Allow Intersector to use your location in iPhone Settings, then ask again.")
				: L10n.text("I couldn't get your location. Please try again.")
		}
		if case OrientError.noIntersections = error {
			if rank > 1 {
				let order = rank == 2 ? L10n.text("second") : L10n.text("third")
				return L10n.text("I couldn't find your %@ %@ intersection. Please try again.", String(describing: order), String(describing: kind == .upcoming ? L10n.text("upcoming") : L10n.text("nearest")))
			}
			return kind == .upcoming
				? L10n.text("I couldn't find an intersection ahead. Try facing along the street and ask again.")
				: L10n.text("I couldn't find a nearby intersection. Please try again.")
		}
		return L10n.text("I can't get intersection information right now. Please try again.")
	}
}
