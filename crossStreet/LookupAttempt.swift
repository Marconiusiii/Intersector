import Foundation
import OSLog

nonisolated enum LookupDeadline {
	@TaskLocal static var current: ContinuousClock.Instant?

	static func serverAllowance(
		until deadline: ContinuousClock.Instant,
		remainingServers: Int,
		now: ContinuousClock.Instant = .now
	) throws -> TimeInterval {
		let duration = now.duration(to: deadline).components
		let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
		guard seconds > 0, remainingServers > 0 else { throw URLError(.timedOut) }
		// Leave a small margin for cancellation, decoding, and returning the result.
		return min(12, seconds * 0.9 / Double(remainingServers))
	}
}

/// Each invocation owns a fresh deadline. Child operations must honor cancellation.
@MainActor
enum LookupAttempt {
	static func run<Value: Sendable>(
		timeout: Duration = .seconds(20),
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
				try await LookupDeadline.$current.withValue(deadline) { try await operation() }
			}
			group.addTask {
				try await Task.sleep(until: deadline, clock: .continuous)
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
	static let logger = Logger(subsystem: "com.marconius.crossStreet", category: "Lookup")
	static func event(_ stage: String, id: String = "", detail: String) {
#if DEBUG
		logger.debug("\(stage, privacy: .public) \(id, privacy: .public): \(detail, privacy: .public)")
#endif
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
