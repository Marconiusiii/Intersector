import Foundation
import Testing
@testable import Intersector

@MainActor
struct LookupDiagnosticsTests {
	@Test func failureCodeExcludesPrivateErrorDetails() {
		let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [
			NSLocalizedDescriptionKey: "private street and coordinate details",
			NSURLErrorFailingURLStringErrorKey: "https://example.com/private-location"
		])
		#expect(LookupDiagnostics.failureCode(error) == "NSURLErrorDomain code=-1001")
		#expect(LookupDiagnostics.failureCode(CancellationError()) == "cancelled")
	}

	@Test func nestedStagesShareRequestIdentifierAndClearItAfterward() async throws {
		#expect(LookupDiagnostics.requestID == nil)
		try await LookupAttempt.run(stage: "test startup") {
			let parent = try #require(LookupDiagnostics.requestID)
			try await LookupAttempt.run(stage: "test location") {
				#expect(LookupDiagnostics.requestID == parent)
			}
		}
		#expect(LookupDiagnostics.requestID == nil)
	}
}
