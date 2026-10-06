import Foundation

/// Overpass can queue requests for 15 seconds before the declared execution time.
nonisolated enum OverpassRequestPolicy {
    static let executionSeconds = 10
    static let queueSeconds = 15
    static let transportSeconds = 5
    static let serverTimeout = TimeInterval(queueSeconds + executionSeconds + transportSeconds)
    static let maximumMemoryBytes = 32 * 1024 * 1024
    static var querySettings: String { "[out:json][timeout:\(executionSeconds)][maxsize:\(maximumMemoryBytes)]" }
}

/// Roads and optional place queries share server health within each app process.
actor OverpassEndpointHealth {
    static let shared = OverpassEndpointHealth()
    private var preferredEndpoint: URL?
    private var unavailableUntil: [URL: Date] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    func orderedEndpoints(primary: URL, fallbacks: [URL]) -> [URL] {
        var seen = Set<URL>()
        let available = ([primary] + fallbacks).filter {
            seen.insert($0).inserted && (unavailableUntil[$0] ?? .distantPast) <= now()
        }
        if let preferredEndpoint, available.contains(preferredEndpoint) {
            return [preferredEndpoint] + available.filter { $0 != preferredEndpoint }
        }
        return available
    }

    func markSuccess(_ endpoint: URL) {
        preferredEndpoint = endpoint
        unavailableUntil[endpoint] = nil
    }

    func markTemporaryFailure(_ endpoint: URL) {
        deferEndpoint(endpoint, until: now().addingTimeInterval(60))
    }

    /// Retry-After can be seconds or an HTTP date. A refusal always gets backoff.
    func recordResponse(_ response: HTTPURLResponse) {
        guard [429, 406].contains(response.statusCode), let endpoint = response.url else { return }
        let current = now()
        var retry = current.addingTimeInterval(60)
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
                retry = max(retry, current.addingTimeInterval(seconds))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: header) { retry = max(retry, date) }
            }
        }
        deferEndpoint(endpoint, until: retry)
        LookupDiagnostics.event("map rate limit", detail: "host=\(endpoint.host ?? "unknown"); status=\(response.statusCode)")
    }

    func retryDate(for endpoint: URL) -> Date? { unavailableUntil[endpoint] }

    private func deferEndpoint(_ endpoint: URL, until date: Date) {
        unavailableUntil[endpoint] = max(unavailableUntil[endpoint] ?? .distantPast, date)
        if preferredEndpoint == endpoint { preferredEndpoint = nil }
    }
}

/// Metadata for the basic nearby-road query. Focused-road queries are not reused.
nonisolated struct OverpassMapArea: Codable, Sendable {
    var latitude: Double
    var longitude: Double
    var radius: Double
    var options: String

    func covers(_ other: Self) -> Bool {
        guard options == other.options else { return false }
        let radians = Double.pi / 180
        let latDelta = (other.latitude - latitude) * radians
        let lonDelta = (other.longitude - longitude) * radians
        let a = pow(sin(latDelta / 2), 2) + cos(latitude * radians) * cos(other.latitude * radians) * pow(sin(lonDelta / 2), 2)
        let distance = 6_371_000 * 2 * atan2(sqrt(max(0, a)), sqrt(max(0, 1 - a)))
        // Preserve the app's existing nearby-area reuse rule.
        return distance + other.radius <= radius || (abs(radius - other.radius) < 1 && distance <= 150)
    }
}

/// Short-lived successful map responses survive process restarts. No location polling.
actor OverpassRoadResponseCache {
    static let shared = OverpassRoadResponseCache(fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("IntersectorOverpass", isDirectory: true).appendingPathComponent("roads-v1.json"))
    private struct Entry: Codable, Sendable {
        var area: OverpassMapArea
        var requestedAt: Date
        var storedAt: Date
        var data: Data
    }
    struct Response: Sendable {
        var area: OverpassMapArea
        var data: Data
        var requestedAt: Date
        var storedAt: Date
    }
    private struct Archive: Codable, Sendable {
        var version = 1
        var entries: [Entry]
    }
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval = 900
    private let maximumEntryBytes = 8 * 1024 * 1024
    private let maximumFileBytes = 32 * 1024 * 1024
    private var entries: [Entry] = []
    private var loaded = false

    init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    func value(for area: OverpassMapArea, minimumRequestedAt: Date? = nil) -> Data? {
        response(for: area, minimumRequestedAt: minimumRequestedAt)?.data
    }

    func response(for area: OverpassMapArea, minimumRequestedAt: Date? = nil) -> Response? {
        loadIfNeeded()
        entries.removeAll { !isCurrent($0) }
        guard let entry = entries.first(where: {
            $0.area.covers(area) && $0.requestedAt >= (minimumRequestedAt ?? .distantPast)
        }) else { return nil }
        LookupDiagnostics.event("map disk cache", detail: "reused successful response")
        return Response(area: entry.area, data: entry.data, requestedAt: entry.requestedAt, storedAt: entry.storedAt)
    }

    func store(_ data: Data, for area: OverpassMapArea, requestedAt: Date) {
        loadIfNeeded()
        guard data.count <= maximumEntryBytes else { return }
        // A late response cannot replace a newer download for this coverage.
        guard !entries.contains(where: { $0.area.covers(area) && $0.requestedAt > requestedAt }) else { return }
        entries.removeAll { !isCurrent($0) || area.covers($0.area) }
        entries.insert(Entry(area: area, requestedAt: requestedAt, storedAt: now(), data: data), at: 0)
        entries = Array(entries.prefix(4))
        persist()
    }

    func discard(for area: OverpassMapArea) {
        loadIfNeeded()
        entries.removeAll { $0.area.covers(area) }
        persist()
    }

    private func isCurrent(_ entry: Entry) -> Bool {
        let age = now().timeIntervalSince(entry.storedAt)
        return age >= 0 && age <= lifetime && entry.data.count <= maximumEntryBytes &&
            entry.area.latitude.isFinite && (-90...90).contains(entry.area.latitude) &&
            entry.area.longitude.isFinite && (-180...180).contains(entry.area.longitude) &&
            entry.area.radius.isFinite && entry.area.radius > 0 && entry.area.radius <= 10_000
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL else { return }
        do {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximumFileBytes else { return }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { return }
            entries = Array(archive.entries.filter(isCurrent).prefix(4))
        } catch {
            // Missing, corrupt, or inaccessible cache files fall back to a download.
            LookupDiagnostics.event("map disk cache", detail: "no usable archive")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            var data = try JSONEncoder().encode(Archive(entries: entries))
            while data.count > maximumFileBytes, !entries.isEmpty {
                entries.removeLast()
                data = try JSONEncoder().encode(Archive(entries: entries))
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
#if os(iOS) || os(watchOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
            try data.write(to: fileURL, options: .atomic)
#endif
        } catch {
            LookupDiagnostics.event("map disk cache", detail: "archive write unavailable")
        }
    }
}
