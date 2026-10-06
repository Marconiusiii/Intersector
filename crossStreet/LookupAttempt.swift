import Foundation
import OSLog

nonisolated enum LookupDeadline {
	static let requestTimeout: Duration = .seconds(60)
	@TaskLocal static var current: ContinuousClock.Instant?

	static func serverAllowance(
		until deadline: ContinuousClock.Instant,
		now: ContinuousClock.Instant = .now
	) throws -> TimeInterval {
		let duration = now.duration(to: deadline).components
		let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
		guard seconds > 0 else { throw URLError(.timedOut) }
		// Allow server queueing, execution, and transport without extending the
		// outer request deadline. Optional operations retain their shorter deadline.
		return min(OverpassRequestPolicy.serverTimeout, seconds)
	}
}

/// Each invocation owns a fresh deadline. Child operations must honor cancellation.
@MainActor
enum LookupAttempt {
	static func run<Value: Sendable>(
		timeout: Duration = LookupDeadline.requestTimeout,
		stage: String = "request",
		operation: @escaping @MainActor @Sendable () async throws -> Value
	) async throws -> Value {
		try Task.checkCancellation()
		let started = ContinuousClock.now
		let identifier = UUID().uuidString
		LookupDiagnostics.event(stage, id: identifier, detail: "started")
		var outcome = "failed or cancelled"
		defer { LookupDiagnostics.event(stage, id: identifier, detail: "\(outcome) after \(started.duration(to: .now))") }
		let ownDeadline = ContinuousClock.now.advanced(by: timeout)
		let deadline = min(LookupDeadline.current ?? ownDeadline, ownDeadline)
		let result = try await withThrowingTaskGroup(of: Value.self) { group in
			group.addTask {
				try await LookupDiagnostics.$requestID.withValue(LookupDiagnostics.requestID ?? identifier) {
					try await LookupDeadline.$current.withValue(deadline) {
						do { return try await operation() }
						catch {
							LookupDiagnostics.event(stage, id: identifier, detail: "failure: \(LookupDiagnostics.failureCode(error))")
							throw error
						}
					}
				}
			}
			group.addTask {
				try await Task.sleep(until: deadline, clock: .continuous)
				LookupDiagnostics.event(stage, id: identifier, detail: "deadline reached")
				throw URLError(.timedOut)
			}
			defer { group.cancelAll() }
			let value = try await group.next()!
			try Task.checkCancellation()
			return value
		}
		outcome = "succeeded"
		return result
	}
}

nonisolated enum LookupDiagnostics {
	@TaskLocal static var requestID: String?
	static let logger = Logger(subsystem: "com.marconius.crossStreet", category: "Lookup")
	static func failureCode(_ error: Error) -> String {
		if error is CancellationError { return "cancelled" }
		let error = error as NSError
		return "\(error.domain) code=\(error.code)"
	}
	static func event(_ stage: String, id: String = "", detail: String) {
		logger.notice("\(stage, privacy: .public) \(id, privacy: .public) request=\(requestID ?? id, privacy: .public): \(detail, privacy: .public)")
	}
}

extension LookupAttempt {
	/// Optional details must leave time to return an already-found intersection.
	static func optional<Value: Sendable>(maximum: Duration = .seconds(2), operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
		let available = ContinuousClock.now.duration(to: LookupDeadline.current ?? .now.advanced(by: .seconds(3)))
		let allowance = min(maximum, available - .milliseconds(300))
		guard allowance > .zero else { throw URLError(.timedOut) }
		return try await run(timeout: allowance, stage: "optional details", operation: operation)
	}
}
