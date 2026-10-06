import CoreLocation
import Foundation
import Testing
@testable import Intersector

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StartupRetryTests {
	private let origin = CLLocationCoordinate2D(latitude: 37, longitude: -122)

	@Test func explicitRefreshIgnoresOlderInFlightWorkAndKeepsNewerResult() async throws {
		let cache = MapDataCache()
		let coordinate = origin
		let gate = RetryTestGate()
		let counter = FetchCounter()
		let first = Task {
			try await cache.data(near: coordinate, radiusMeters: 225) {
				await gate.wait()
				return await counter.nextDataSet()
			}
		}
		await gate.waitUntilEntered()
		let cutoff = Date()
		let refreshed = try await cache.data(near: coordinate, radiusMeters: 225, minimumRequestedAt: cutoff) {
			await counter.nextDataSet()
		}
		#expect(refreshed.intersections.first?.id == "fetch-1")
		await gate.release()
		_ = try await first.value
		let cached = try await cache.data(near: coordinate, radiusMeters: 225) { await counter.nextDataSet() }
		#expect(cached.intersections.first?.id == "fetch-1")
		#expect(await counter.count == 2)
	}

	@Test func explicitRefreshKeepsOtherAreasAndReusesItsNewData() async throws {
		let cache = MapDataCache()
		let counter = FetchCounter()
		let distant = CLLocationCoordinate2D(latitude: 39, longitude: -122)
		_ = try await cache.data(near: distant, radiusMeters: 225) { await counter.nextDataSet() }
		_ = try await cache.data(near: origin, radiusMeters: 225) { await counter.nextDataSet() }
		let cutoff = Date()
		let refresh = try await cache.data(near: origin, radiusMeters: 225, minimumRequestedAt: cutoff) { await counter.nextDataSet() }
		let reused = try await cache.data(near: origin, radiusMeters: 225, minimumRequestedAt: cutoff) { await counter.nextDataSet() }
		let other = try await cache.data(near: distant, radiusMeters: 225) { await counter.nextDataSet() }
		#expect(refresh.intersections.first?.id == "fetch-3")
		#expect(reused.intersections.first?.id == "fetch-3")
		#expect(other.intersections.first?.id == "fetch-1")
		#expect(await counter.count == 3)
	}

	@Test func mapClientPassesRefreshRequirementToBothCachePaths() async throws {
		var client = MapDataClient()
		client.endpoint = URL(string: "https://siri-refresh-\(UUID().uuidString).example")!
		client.fallbackEndpoints = []
		let log = ServerBudgetLog()
		client.requestHandler = { request in
			await log.begin(request)
			await log.end()
			return MapHTTPResponse(data: Data("{\"elements\":[]}".utf8),
				response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		let coordinate = CLLocationCoordinate2D(latitude: 46.123456, longitude: -71.987654)
		_ = try await client.mapData(near: coordinate, radiusMeters: 225)
		_ = try await client.mapData(near: coordinate, radiusMeters: 225)
		#expect(await log.urls.count == 1)
		client.minimumCacheDate = Date()
		_ = try await client.immediateMapData(near: coordinate, radiusMeters: 225)
		#expect(await log.urls.count == 2)
		client.minimumCacheDate = Date()
		_ = try await client.mapData(near: coordinate, radiusMeters: 225)
		#expect(await log.urls.count == 3)
	}

	@Test func incompleteSuccessfulHTTPResponseUsesFallbackInsteadOfCachingEmptyData() async throws {
		var client = MapDataClient()
		let primary = URL(string: "https://incomplete-\(UUID().uuidString).example")!
		client.endpoint = primary
		client.fallbackEndpoints = [URL(string: "https://complete-\(UUID().uuidString).example")!]
		let log = ServerBudgetLog()
		client.requestHandler = { request in
			await log.begin(request)
			await log.end()
			let body = request.url == primary ? "{\"remark\":\"runtime error: timeout\",\"elements\":[]}" : "{\"elements\":[]}"
			return MapHTTPResponse(data: Data(body.utf8), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		_ = try await client.freshMapData(near: origin, radiusMeters: 225)
		#expect(await log.urls.count == 2)
	}

	@Test func failedFetchDoesNotPoisonImmediateRetry() async throws {
		let cache = MapDataCache()
		let counter = FetchCounter()
		do {
			_ = try await cache.data(near: origin, radiusMeters: 225) { throw URLError(.notConnectedToInternet) }
			Issue.record("Expected the first request to fail")
		} catch {}
		let data = try await cache.data(near: origin, radiusMeters: 225) { await counter.nextDataSet() }
		#expect(data.intersections.first?.id == "fetch-1")
	}

	@Test func timedOutFetchAllowsImmediateRetryWithFreshBudget() async throws {
		let cache = MapDataCache()
		let coordinate = origin
		let counter = FetchCounter()
		do {
			_ = try await LookupAttempt.run(timeout: .milliseconds(30)) {
				try await cache.data(near: coordinate, radiusMeters: 225) {
					try await Task.sleep(for: .seconds(30))
					return await counter.nextDataSet()
				}
			}
			Issue.record("Expected timeout")
		} catch { #expect((error as? URLError)?.code == .timedOut) }
		let data = try await LookupAttempt.run(timeout: .seconds(1)) {
			try await cache.data(near: coordinate, radiusMeters: 225) {
				try await Task.sleep(for: .milliseconds(60))
				return await counter.nextDataSet()
			}
		}
		#expect(data.intersections.first?.id == "fetch-1")
	}

	@Test func cancelledOldFetchCannotOverwriteSuccessfulRetry() async throws {
		let cache = MapDataCache()
		let coordinate = origin
		let gate = RetryTestGate()
		let counter = FetchCounter()
		let first = Task {
			try await cache.data(near: coordinate, radiusMeters: 225) {
				await gate.wait() // Deliberately ignores cancellation to simulate a late completion.
				return await counter.nextDataSet()
			}
		}
		await gate.waitUntilEntered()
		first.cancel()
		do { _ = try await first.value; Issue.record("Expected cancellation") } catch is CancellationError {} 
		let retry = try await cache.data(near: coordinate, radiusMeters: 225) { await counter.nextDataSet() }
		await gate.release()
		try await Task.sleep(for: .milliseconds(30))
		let cached = try await cache.data(near: coordinate, radiusMeters: 225) { await counter.nextDataSet() }
		#expect(retry.intersections.first?.id == "fetch-1")
		#expect(cached.intersections.first?.id == "fetch-1")
	}

	@Test func concurrentCallersShareFetchAndCancellationKeepsOtherWaiter() async throws {
		let cache = MapDataCache()
		let coordinate = origin
		let gate = RetryTestGate()
		let counter = FetchCounter()
		let first = Task {
			try await cache.data(near: coordinate, radiusMeters: 225) {
				await gate.wait()
				return await counter.nextDataSet()
			}
		}
		await gate.waitUntilEntered()
		let second = Task {
			try await cache.data(near: coordinate, radiusMeters: 225) { await counter.nextDataSet() }
		}
		while await cache.activeWaiterCount < 2 { await Task.yield() }
		first.cancel()
		do { _ = try await first.value; Issue.record("Expected cancellation") } catch is CancellationError {}
		await gate.release()
		let result = try await second.value
		#expect(result.intersections.first?.id == "fetch-1")
		#expect(await counter.count == 1)
	}

	@Test func olderAreaCompletionDoesNotClearNewerAreaRequest() async throws {
		let cache = MapDataCache()
		let gateA = RetryTestGate()
		let gateB = RetryTestGate()
		let counter = FetchCounter()
		let coordinate = origin
		let distant = CLLocationCoordinate2D(latitude: 38, longitude: -122)
		let first = Task { try await cache.data(near: coordinate, radiusMeters: 225) { await gateA.wait(); return await counter.nextDataSet() } }
		await gateA.waitUntilEntered()
		let second = Task { try await cache.data(near: distant, radiusMeters: 225) { await gateB.wait(); return await counter.nextDataSet() } }
		await gateB.waitUntilEntered()
		await gateA.release()
		_ = try await first.value
		let joined = Task { try await cache.data(near: distant, radiusMeters: 225) { await counter.nextDataSet() } }
		while await cache.activeWaiterCount < 2 { await Task.yield() }
		await gateB.release()
		let secondData = try await second.value
		let joinedData = try await joined.value
		#expect(secondData.intersections.first?.id == joinedData.intersections.first?.id)
		#expect(await counter.count == 2)
	}

	@Test func neighbourhoodTimeoutDoesNotTrapRetry() async throws {
		let cache = NeighborhoodCache()
		let coordinate = origin
		do {
			_ = try await LookupAttempt.run(timeout: .milliseconds(30)) {
				try await cache.data(near: coordinate, radiusMeters: 225) {
					try await Task.sleep(for: .seconds(30))
					return []
				}
			}
			Issue.record("Expected timeout")
		} catch { #expect((error as? URLError)?.code == .timedOut) }
		let data = try await LookupAttempt.run(timeout: .seconds(1)) {
			try await cache.data(near: coordinate, radiusMeters: 225) { [] }
		}
		#expect(data.isEmpty)
	}

	@Test func offlineFailureDoesNotPutHealthyServerInCooldown() async throws {
		var client = MapDataClient()
		client.endpoint = URL(string: "https://offline-retry-\(UUID().uuidString).example")!
		client.fallbackEndpoints = []
		client.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
		do {
			_ = try await client.freshMapData(near: origin, radiusMeters: 225)
			Issue.record("Expected offline failure")
		} catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
		client.requestHandler = { request in
			MapHTTPResponse(data: Data("{\"elements\":[]}".utf8),
				response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		let data = try await client.freshMapData(near: origin, radiusMeters: 225)
		#expect(data.intersections.isEmpty)
	}

	@Test func serverAllowanceIsNotDividedBetweenFallbacks() throws {
		let now = ContinuousClock.now
		#expect(try LookupDeadline.serverAllowance(until: now.advanced(by: .seconds(60)), now: now) == 12)
		#expect(try LookupDeadline.serverAllowance(until: now.advanced(by: .seconds(52)), now: now) == 12)
		#expect(try LookupDeadline.serverAllowance(until: now.advanced(by: .seconds(8)), now: now) == 8)
	}

	@Test func localTimeoutDoesNotBlacklistEndpointForExplicitRetry() async throws {
		var client = MapDataClient()
		client.endpoint = URL(string: "https://local-timeout-\(UUID().uuidString).example")!
		client.fallbackEndpoints = []
		client.requestHandler = { _ in throw URLError(.timedOut) }
		do { _ = try await client.freshMapData(near: origin, radiusMeters: 225); Issue.record("Expected timeout") }
		catch { #expect((error as? URLError)?.code == .timedOut) }
		let log = ServerBudgetLog()
		client.requestHandler = { request in
			await log.begin(request)
			await log.end()
			return MapHTTPResponse(data: Data("{\"elements\":[]}".utf8), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		_ = try await client.freshMapData(near: origin, radiusMeters: 225)
		#expect(await log.urls.count == 1)
	}

	@Test func sequentialFallbacksEachReceiveFullAllowance() async throws {
		let hosts = (0..<3).map { URL(string: "https://full-allowance-\(UUID().uuidString)-\($0).example")! }
		let log = ServerBudgetLog()
		var client = MapDataClient()
		client.endpoint = hosts[0]
		client.fallbackEndpoints = Array(hosts.dropFirst())
		client.requestHandler = { request in
			await log.begin(request)
			await log.end()
			if request.url != hosts[2] { throw URLError(.timedOut) }
			return MapHTTPResponse(data: Data("{\"elements\":[]}".utf8), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		let configured = client
		let coordinate = origin
		_ = try await LookupAttempt.run { try await configured.freshMapData(near: coordinate, radiusMeters: 225) }
		#expect(await log.urls == hosts)
		#expect(await log.allowances == [12, 12, 12])
		#expect(await log.maximumActive == 1)
	}

	@Test func expiredBudgetDoesNotPutUntriedServerInCooldown() async throws {
		var client = MapDataClient()
		client.endpoint = URL(string: "https://untried-\(UUID().uuidString).example")!
		client.fallbackEndpoints = []
		let log = ServerBudgetLog()
		client.requestHandler = { request in
			await log.begin(request)
			await log.end()
			return MapHTTPResponse(data: Data("{\"elements\":[]}".utf8),
				response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
		}
		let configured = client
		do {
			_ = try await LookupDeadline.$current.withValue(.now.advanced(by: .seconds(-1))) {
				try await configured.freshMapData(near: origin, radiusMeters: 225)
			}
			Issue.record("Expected expired budget")
		} catch { #expect((error as? URLError)?.code == .timedOut) }
		#expect(await log.urls.isEmpty)
		_ = try await configured.freshMapData(near: origin, radiusMeters: 225)
		#expect(await log.urls.count == 1)
	}

	@Test func coolingDownServersAreNotImmediatelyRetried() async throws {
		let health = MapEndpointHealth()
		let primary = URL(string: "https://startup-primary.example")!
		let fallback = URL(string: "https://startup-fallback.example")!
		await health.markTemporaryFailure(primary)
		#expect(await health.orderedEndpoints(primary: primary, fallbacks: [fallback]) == [fallback])
		await health.markTemporaryFailure(fallback)
		#expect(await health.orderedEndpoints(primary: primary, fallbacks: [fallback]).isEmpty)
	}
}

private actor RetryTestGate {
	private var entered = false
	private var waiter: CheckedContinuation<Void, Never>?
	func wait() async {
		entered = true
		await withCheckedContinuation { waiter = $0 }
	}
	func waitUntilEntered() async {
		while !entered { await Task.yield() }
	}
	func release() { waiter?.resume(); waiter = nil }
}

private actor ServerBudgetLog {
	private(set) var urls: [URL] = []
	private(set) var allowances: [TimeInterval] = []
	private var active = 0
	private(set) var maximumActive = 0
	func begin(_ request: URLRequest) {
		urls.append(request.url!)
		allowances.append(request.timeoutInterval)
		active += 1
		maximumActive = max(maximumActive, active)
	}
	func end() { active -= 1 }
}
