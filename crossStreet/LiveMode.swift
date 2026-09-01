//
//  LiveMode.swift
//  Intersector
//

import AVFoundation
import CoreLocation
import Foundation

enum LiveTravelMode: String, CaseIterable, Identifiable, Sendable {
	case walking
	case driving

	var id: String { rawValue }

	var label: String {
		switch self {
		case .walking:
			"Walking"
		case .driving:
			"Driving"
		}
	}

	var mapRadiusMeters: CLLocationDistance {
		1_200
	}

	var announcementDistanceMeters: CLLocationDistance {
		switch self {
		case .walking:
			90
		case .driving:
			350
		}
	}
}

struct LiveSpeechSettings: Equatable, Sendable {
	var voiceIdentifier: String
	var ratePercent: Int
	var volume: Float
}

struct LiveUpcomingResult: Equatable {
	var primaryIntersectionID: String
	var distanceMeters: CLLocationDistance
	var text: String
}

struct LiveRoadMatch: Equatable {
	var context: DeviceContext
	var roadName: String
	var score: Double
}

struct LiveRoadMatcher {
	private(set) var samples: [DeviceContext] = []
	private(set) var previousRoadName: String?
	private let maximumSampleCount = 6

	mutating func reset() {
		samples = []
		previousRoadName = nil
	}

	mutating func match(
		_ context: DeviceContext,
		in mapData: MapDataSet,
		mode: LiveTravelMode
	) -> LiveRoadMatch? {
		guard (context.horizontalAccuracy ?? 0) >= 0, (context.horizontalAccuracy ?? 85) <= 100 else {
			return nil
		}

		samples.append(context)
		if samples.count > maximumSampleCount {
			samples.removeFirst(samples.count - maximumSampleCount)
		}

		guard let direction = travelDirection(for: context) else {
			return nil
		}
		let accuracy = context.horizontalAccuracy ?? 25
		let maximumRoadDistance = max(30, min(accuracy + 20, 75))
		let candidates = mapData.roads.compactMap { road -> LiveRoadMatch? in
			guard roadIsAllowed(road, mode: mode) else {
				return nil
			}
			let distance = road.minimumDistance(to: context.coordinate)
			guard
				distance <= maximumRoadDistance,
				let alignment = road.directionSign(for: direction, at: context.coordinate),
				abs(alignment) >= 0.35
			else {
				return nil
			}
			let alignmentPenalty = (1 - abs(alignment)) * 45
			let continuityAdjustment = road.name == previousRoadName ? -18.0 : 0
			let score = distance + alignmentPenalty + continuityAdjustment
			var matchedContext = context
			matchedContext.headingDegrees = direction
			return LiveRoadMatch(context: matchedContext, roadName: road.name, score: score)
		}

		guard let match = candidates.min(by: { $0.score < $1.score }) else {
			return nil
		}
		previousRoadName = match.roadName
		return match
	}

	private func travelDirection(for latest: DeviceContext) -> CLLocationDirection? {
		if
			let course = latest.courseDegrees,
			let accuracy = latest.courseAccuracy,
			let speed = latest.speedMetersPerSecond,
			course >= 0,
			accuracy >= 0,
			accuracy <= 45,
			speed >= 0.7
		{
			return course
		}

		guard let earlier = samples.dropLast().first else {
			return nil
		}
		let distance = Geo.distanceMeters(from: earlier.coordinate, to: latest.coordinate)
		let accuracyFloor = max(10, min((earlier.horizontalAccuracy ?? 10) + (latest.horizontalAccuracy ?? 10), 30))
		guard distance >= accuracyFloor else {
			return nil
		}
		return Geo.bearingDegrees(from: earlier.coordinate, to: latest.coordinate)
	}

	private func roadIsAllowed(_ road: MapRoad, mode: LiveTravelMode) -> Bool {
		guard mode == .driving else {
			return true
		}
		return !["footway", "path", "steps", "bridleway", "pedestrian"].contains(road.highway)
	}
}

struct LiveAnnouncementGate {
	private var announcedAt: [String: Date] = [:]
	private let repeatCooldown: TimeInterval = 10 * 60

	mutating func reset() {
		announcedAt = [:]
	}

	mutating func shouldAnnounce(
		intersectionID: String,
		distanceMeters: CLLocationDistance,
		mode: LiveTravelMode,
		now: Date = .now
	) -> Bool {
		announcedAt = announcedAt.filter { now.timeIntervalSince($0.value) < repeatCooldown }
		guard distanceMeters <= mode.announcementDistanceMeters else {
			return false
		}
		guard announcedAt[intersectionID] == nil else {
			return false
		}
		announcedAt[intersectionID] = now
		return true
	}
}

struct LiveMovementMonitor {
	private(set) var anchor: CLLocationCoordinate2D?
	private(set) var lastMeaningfulMovementAt: Date?

	mutating func reset(at date: Date = .now) {
		anchor = nil
		lastMeaningfulMovementAt = date
	}

	mutating func record(_ context: DeviceContext, at date: Date = .now) {
		guard let anchor else {
			self.anchor = context.coordinate
			lastMeaningfulMovementAt = date
			return
		}
		let accuracy = context.horizontalAccuracy ?? 20
		let movementThreshold = max(25, min(accuracy * 1.5, 60))
		guard Geo.distanceMeters(from: anchor, to: context.coordinate) >= movementThreshold else {
			return
		}
		self.anchor = context.coordinate
		lastMeaningfulMovementAt = date
	}

	func hasTimedOut(after minutes: Double, at date: Date = .now) -> Bool {
		guard let lastMeaningfulMovementAt else {
			return false
		}
		return date.timeIntervalSince(lastMeaningfulMovementAt) >= minutes * 60
	}
}

@MainActor
final class SystemSpeechController {
	static let shared = SystemSpeechController()

	private let synthesizer = AVSpeechSynthesizer()

	func speak(_ text: String, settings: LiveSpeechSettings, delay: TimeInterval = 0) {
		guard !text.isEmpty else {
			return
		}
		prepareAudioSession()
		synthesizer.stopSpeaking(at: .immediate)
		let utterance = AVSpeechUtterance(string: text)
		if !settings.voiceIdentifier.isEmpty {
			utterance.voice = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier)
		}
		utterance.rate = Self.speechRate(forPercent: settings.ratePercent)
		utterance.volume = min(1, max(0, settings.volume))
		utterance.preUtteranceDelay = max(0, delay)
		synthesizer.speak(utterance)
	}

	func stop() {
		synthesizer.stopSpeaking(at: .immediate)
	}

	private func prepareAudioSession() {
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
			try session.setActive(true)
		} catch {}
	}

	static func speechRate(forPercent percent: Int) -> Float {
		let clamped = min(max(percent, 0), 100)
		let progress = Float(clamped) / 100
		return AVSpeechUtteranceMinimumSpeechRate
			+ ((AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * progress)
	}
}

struct LiveSpeechVoice: Identifiable, Equatable {
	var id: String
	var label: String

	static var available: [LiveSpeechVoice] {
		let systemDefault = LiveSpeechVoice(id: "", label: "System Default")
		guard let deviceLanguageCode = Locale.current.language.languageCode?.identifier else {
			return [systemDefault]
		}
		let installed = AVSpeechSynthesisVoice.speechVoices()
			.filter { matchesDeviceLanguage(voiceLanguage: $0.language, deviceLanguageCode: deviceLanguageCode) }
			.sorted {
				let firstRank = sortRank(for: $0)
				let secondRank = sortRank(for: $1)
				if firstRank != secondRank {
					return firstRank < secondRank
				}
				return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
			}
			.map { voice in
				LiveSpeechVoice(id: voice.identifier, label: "\(voice.name), \(voice.language)")
			}
		return [systemDefault] + installed
	}

	static func matchesDeviceLanguage(voiceLanguage: String, deviceLanguageCode: String) -> Bool {
		guard
			let voiceCode = Locale(identifier: voiceLanguage).language.languageCode?.identifier,
			let deviceCode = Locale(identifier: deviceLanguageCode).language.languageCode?.identifier
		else {
			return false
		}
		return voiceCode.caseInsensitiveCompare(deviceCode) == .orderedSame
	}

	private static func sortRank(for voice: AVSpeechSynthesisVoice) -> Int {
		let qualityRank: Int
		switch voice.quality {
		case .premium:
			qualityRank = 0
		case .enhanced:
			qualityRank = 1
		default:
			qualityRank = 2
		}

		if #available(iOS 17.0, *), voice.voiceTraits.contains(.isNoveltyVoice) {
			return qualityRank + 10
		}
		return qualityRank
	}
}
