import Foundation

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
		operation: @escaping @MainActor @Sendable () async throws -> Value
	) async throws -> Value {
		try Task.checkCancellation()
		let ownDeadline = ContinuousClock.now.advanced(by: timeout)
		let deadline = min(LookupDeadline.current ?? ownDeadline, ownDeadline)
		return try await withThrowingTaskGroup(of: Value.self) { group in
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
	}
}
