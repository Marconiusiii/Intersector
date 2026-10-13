//
//  ContentView.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import AVFoundation
import Darwin
import MessageUI
import SwiftUI
import UIKit
import WatchConnectivity

private enum DisplayLayout: String, CaseIterable, Identifiable {
	case standard
	case centered

	var id: String { rawValue }

	var label: String {
		switch self {
		case .standard:
			"Default"
		case .centered:
			"Centered"
		}
	}
}

private struct AcknowledgementsSettingsButton: View {
	@State private var isShowingAcknowledgements = false
	@AccessibilityFocusState private var isButtonFocused: Bool

	var body: some View {
		Button {
			isShowingAcknowledgements = true
		} label: {
			Text("Acknowledgements")
				.font(.body)
				.fontWeight(.semibold)
				.foregroundStyle(Color.crossAccent)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
		}
		.buttonStyle(.plain)
		.accessibilityFocused($isButtonFocused)
		.sheet(
			isPresented: $isShowingAcknowledgements,
			onDismiss: restoreButtonFocus
		) {
			AcknowledgementsView()
		}
	}

	private func restoreButtonFocus() {
		isButtonFocused = false

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
			isButtonFocused = true
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
			isButtonFocused = true
		}
	}
}

private struct AcknowledgementsView: View {
	@Environment(\.dismiss) private var dismiss
	@AccessibilityFocusState private var isHeadingFocused: Bool

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					Text("Acknowledgements")
						.font(.largeTitle)
						.fontWeight(.bold)
						.foregroundStyle(Color.crossText)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityAddTraits(.isHeader)
						.accessibilityFocused($isHeadingFocused)

					Text("Special thanks to Jen Walz for inspiring the creation of this app!")
						.font(.body)
						.foregroundStyle(Color.crossText)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)

					Text("Map data from OpenStreetMap, available under the Open Database License.")
						.font(.body)
						.foregroundStyle(Color.crossText)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)

					Link(
						"OpenStreetMap copyright and licence",
						destination: URL(string: "https://www.openstreetmap.org/copyright")!
					)
					.font(.body)
					.foregroundStyle(Color.crossAccent)
					.underline()
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
					.accessibilityTouchRegion(minHeight: 60, verticalPadding: 4, alignment: .leading)
					.accessibilityAddTraits(.isLink)
					.accessibilityRemoveTraits(.isButton)
					.accessibilityHint("Opens in external browser")
				}
				.padding(24)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.scrollContentBackground(.hidden)
			.background(Color.crossBg)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") {
						dismiss()
					}
				}
			}
		}
		.tint(Color.crossAccent)
		.onAppear {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
				isHeadingFocused = true
			}
		}
	}
}

private struct PersistentScanButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
	}
}

private struct LiveVoicePicker: View {
	@Binding var voiceIdentifier: String

	private var voices: [LiveSpeechVoice] {
		LiveSpeechVoice.available
	}

	var body: some View {
		Picker("Voice", selection: $voiceIdentifier) {
			ForEach(voices) { voice in
				Text(voice.label).tag(voice.id)
			}
		}
		.pickerStyle(.wheel)
		.onAppear {
			if !voices.contains(where: { $0.id == voiceIdentifier }) {
				voiceIdentifier = ""
			}
		}
	}
}

private let lookupLoadingText = "Still finding the intersection."
private let extendedLookupLoadingText = "Still working. Map data is taking longer than usual."
private let startupLoadingText = "Loading Intersector..."
private let mapPreparationText = "Preparing map data for Nearest and Upcoming."
private let mapWaitingText = "Waiting for map data. Nearest and Upcoming will become available automatically."
private let readyText = "Intersector Ready."

@MainActor
private enum LoadingThrobber {
	private static var player: AVAudioPlayer?
	private static var hapticTask: Task<Void, Never>?
	private static let loopDuration: TimeInterval = 2.20

	static func start(hapticsEnabled: Bool) {
		do {
			if player == nil {
				player = try AVAudioPlayer(data: cueData())
				// Individual note gains are encoded in the audio samples.
				player?.volume = 0.5
				player?.numberOfLoops = -1
				player?.prepareToPlay()
			}
			player?.currentTime = 0
			if let player { IntersectorAudioSession.shared.play(player) }
		} catch {}
		startHapticsIfNeeded(hapticsEnabled)
	}

	static func stop() {
		hapticTask?.cancel()
		hapticTask = nil
		guard let endingPlayer = player else { return }
		// Detach this playback so its release cannot stop a newly started loop.
		player = nil
		endingPlayer.setVolume(0, fadeDuration: 0.20)
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(200))
			IntersectorAudioSession.shared.stop(endingPlayer)
		}
	}

	private static func cueData() -> Data {
		let sampleRate = 22_050
		let duration = loopDuration
		let frameCount = Int(Double(sampleRate) * duration)
		let dataSize = frameCount * MemoryLayout<Int16>.size
		var data = Data()
		data.append(contentsOf: "RIFF".utf8)
		data.append(UInt32(36 + dataSize).littleEndianData)
		data.append(contentsOf: "WAVEfmt ".utf8)
		data.append(UInt32(16).littleEndianData)
		data.append(UInt16(1).littleEndianData)
		data.append(UInt16(1).littleEndianData)
		data.append(UInt32(sampleRate).littleEndianData)
		data.append(UInt32(sampleRate * MemoryLayout<Int16>.size).littleEndianData)
		data.append(UInt16(MemoryLayout<Int16>.size).littleEndianData)
		data.append(UInt16(16).littleEndianData)
		data.append(contentsOf: "data".utf8)
		data.append(UInt32(dataSize).littleEndianData)

		var samples: [Double] = []
		samples.reserveCapacity(frameCount)
		for index in 0..<frameCount {
			let time = Double(index) / Double(sampleRate)
			let pad = padValue(time: time, duration: duration) * 0.16
			let pulses = pulseValue(
				time: time,
				start: 0.12,
				attack: 0.025,
				decay: 0.20,
				sustain: 0.05,
				frequency: 660, gain: 0.45
			) + pulseValue(
				time: time,
				start: 0.48,
				attack: 0.03,
				decay: 0.24,
				sustain: 0.07,
				frequency: 330, gain: 0.36
			) + pulseValue(
				time: time,
				start: 0.86,
				attack: 0.03,
				decay: 0.36,
				sustain: 0,
				frequency: 494, gain: 0.25
			)
			samples.append(pad + pulses)
		}

		let echoedSamples = samples.addingEcho(
			sampleRate: sampleRate,
			taps: [
				(delay: 0.14, gain: 0.24),
				(delay: 0.31, gain: 0.11)
			]
		)
		data.append(echoedSamples.pcm(normalize: false))

		return data
	}

	private static func startHapticsIfNeeded(_ isEnabled: Bool) {
		hapticTask?.cancel()
		guard isEnabled else {
			hapticTask = nil
			return
		}
		hapticTask = Task { @MainActor in
			let pulses: [(offset: TimeInterval, intensity: Double)] = [
				(0.12, 0.95),
				(0.48, 0.55),
				(0.86, 0.25)
			]
			var firedPulseIndexes = Set<Int>()
			var previousPlaybackTime: TimeInterval = 0
			while !Task.isCancelled {
				guard
					let player,
					player.isPlaying
				else {
					try? await Task.sleep(for: .milliseconds(20))
					continue
				}
				let playbackTime = player.currentTime
				if playbackTime < previousPlaybackTime || playbackTime < 0.08 {
					firedPulseIndexes.removeAll()
				}
				for (index, pulse) in pulses.enumerated() where
					playbackTime >= pulse.offset &&
					previousPlaybackTime < pulse.offset &&
					!firedPulseIndexes.contains(index)
				{
					HapticFeedback().pulse(intensity: pulse.intensity)
					firedPulseIndexes.insert(index)
				}
				previousPlaybackTime = playbackTime
				try? await Task.sleep(for: .milliseconds(16))
			}
		}
	}

	private static func padValue(time: Double, duration: Double) -> Double {
		let fadeIn = min(1, time / 0.36)
		let fadeOut = min(1, max(0, (1.55 - time) / 0.45))
		let envelope = max(0, min(fadeIn, fadeOut))
		let base = sin(2 * Double.pi * 247 * time)
		let shimmer = sin(2 * Double.pi * 330 * time) * 0.35
		return (base + shimmer) * envelope * 0.14
	}

	private static func pulseValue(
		time: Double,
		start: Double,
		attack: Double,
		decay: Double,
		sustain: Double,
		frequency: Double,
		gain: Double
	) -> Double {
		let duration = attack + decay + sustain
		guard time >= start, time <= start + duration else {
			return 0
		}
		let localTime = time - start
		let envelope: Double
		if localTime <= attack {
			envelope = localTime / attack
		} else if localTime <= attack + sustain {
			envelope = 1
		} else {
			let decayProgress = (localTime - attack - sustain) / decay
			envelope = max(0, 1 - decayProgress)
		}
		let angle = 2 * Double.pi * frequency * localTime
		return sin(angle) * envelope * gain
	}
}

private extension FixedWidthInteger {
	var littleEndianData: Data {
		var value = littleEndian
		return Data(bytes: &value, count: MemoryLayout<Self>.size)
	}
}

@MainActor
private enum ReadyEarcon {
	private static var player: AVAudioPlayer?
	private static var hapticTask: Task<Void, Never>?
	private static let noteStarts: [TimeInterval] = [0.16, 0.52, 0.92]

	static func play(hapticsEnabled: Bool) {
		do {
			let previousPlayer = player
			player = try AVAudioPlayer(data: cueData())
			// Individual note gains are encoded in the audio samples.
			player?.volume = 0.5
			player?.prepareToPlay()
			if let player { IntersectorAudioSession.shared.play(player, replacing: previousPlayer) }
		} catch {}
		playHapticsIfNeeded(hapticsEnabled)
	}

	private static func cueData() -> Data {
		let sampleRate = 22_050
		// Include the final note's release and the complete echo tail.
		let duration = 1.80
		let frameCount = Int(Double(sampleRate) * duration)
		let dataSize = frameCount * MemoryLayout<Int16>.size
		var data = Data()
		data.append(contentsOf: "RIFF".utf8)
		data.append(UInt32(36 + dataSize).littleEndianData)
		data.append(contentsOf: "WAVEfmt ".utf8)
		data.append(UInt32(16).littleEndianData)
		data.append(UInt16(1).littleEndianData)
		data.append(UInt16(1).littleEndianData)
		data.append(UInt32(sampleRate).littleEndianData)
		data.append(UInt32(sampleRate * MemoryLayout<Int16>.size).littleEndianData)
		data.append(UInt16(MemoryLayout<Int16>.size).littleEndianData)
		data.append(UInt16(16).littleEndianData)
		data.append(contentsOf: "data".utf8)
		data.append(UInt32(dataSize).littleEndianData)

		var samples: [Double] = []
		samples.reserveCapacity(frameCount)
		for index in 0..<frameCount {
			let time = Double(index) / Double(sampleRate)
			let pad = readyPadValue(time: time) * 0.13
			let pulses = readyPulse(time: time, start: noteStarts[0], frequency: 494, gain: 0.25)
				+ readyPulse(time: time, start: noteStarts[1], frequency: 660, gain: 0.36)
				+ readyPulse(time: time, start: noteStarts[2], frequency: 988, gain: 0.45)
			samples.append(pad + pulses)
		}

		let echoedSamples = samples.addingEcho(
			sampleRate: sampleRate,
			taps: [
				(delay: 0.15, gain: 0.22),
				(delay: 0.34, gain: 0.10)
			]
		)
		data.append(echoedSamples.pcm(normalize: false))
		return data
	}

	private static func readyPadValue(time: Double) -> Double {
		let fadeIn = min(1, time / 0.24)
		let fadeOut = min(1, max(0, (1.34 - time) / 0.38))
		let envelope = max(0, min(fadeIn, fadeOut))
		let base = sin(2 * Double.pi * 247 * time)
		let shimmer = sin(2 * Double.pi * 370 * time) * 0.32
		return (base + shimmer) * envelope * 0.15
	}

	private static func readyPulse(
		time: Double,
		start: Double,
		frequency: Double,
		gain: Double
	) -> Double {
		let attack = 0.028
		let sustain = 0.12
		let decay = 0.38
		let duration = attack + sustain + decay
		guard time >= start, time <= start + duration else {
			return 0
		}
		let localTime = time - start
		let envelope: Double
		if localTime <= attack {
			envelope = localTime / attack
		} else if localTime <= attack + sustain {
			envelope = 1
		} else {
			let decayProgress = (localTime - attack - sustain) / decay
			envelope = (1 + cos(Double.pi * decayProgress)) / 2
		}
		let angle = 2 * Double.pi * frequency * localTime
		return sin(angle) * envelope * gain
	}

	private static func playHapticsIfNeeded(_ isEnabled: Bool) {
		hapticTask?.cancel()
		guard isEnabled else {
			hapticTask = nil
			return
		}
		hapticTask = Task { @MainActor in
			let clock = ContinuousClock()
			let startTime = clock.now
			let pulses: [(offset: Duration, intensity: Double)] = [
				(.milliseconds(Int(noteStarts[0] * 1_000)), 0.25),
				(.milliseconds(Int(noteStarts[1] * 1_000)), 0.55),
				(.milliseconds(Int(noteStarts[2] * 1_000)), 0.95)
			]
			for pulse in pulses {
				let targetTime = startTime + pulse.offset
				if clock.now < targetTime {
					try? await Task.sleep(until: targetTime, clock: clock)
				}
				guard !Task.isCancelled else { return }
				HapticFeedback().pulse(intensity: pulse.intensity)
			}
		}
	}
}

@MainActor
enum LiveModeEarcon {
	static let speechDelay: TimeInterval = 0.78

	private static var player: AVAudioPlayer?
	private static var hapticTask: Task<Void, Never>?
	private static let noteStarts: [TimeInterval] = [0.06, 0.24, 0.42]

	static func play(isActive: Bool, hapticsEnabled: Bool) {
		do {
			let previousPlayer = player
			player = try AVAudioPlayer(data: cueData(isActive: isActive))
			// Individual note gains are encoded in the audio samples.
			player?.volume = 0.5
			player?.prepareToPlay()
			if let player { IntersectorAudioSession.shared.play(player, replacing: previousPlayer) }
		} catch {}
		playHapticsIfNeeded(isActive: isActive, hapticsEnabled: hapticsEnabled)
	}

	static func frequencies(isActive: Bool) -> [Double] {
		isActive ? [494, 660, 988] : [988, 660, 494]
	}

	private static func cueData(isActive: Bool) -> Data {
		let sampleRate = 22_050
		// Let the quiet release finish without delaying the spoken status.
		let duration = isActive ? 1.06 : 1.0
		let frameCount = Int(Double(sampleRate) * duration)
		let dataSize = frameCount * MemoryLayout<Int16>.size
		var data = Data()
		data.append(contentsOf: "RIFF".utf8)
		data.append(UInt32(36 + dataSize).littleEndianData)
		data.append(contentsOf: "WAVEfmt ".utf8)
		data.append(UInt32(16).littleEndianData)
		data.append(UInt16(1).littleEndianData)
		data.append(UInt16(1).littleEndianData)
		data.append(UInt32(sampleRate).littleEndianData)
		data.append(UInt32(sampleRate * MemoryLayout<Int16>.size).littleEndianData)
		data.append(UInt16(MemoryLayout<Int16>.size).littleEndianData)
		data.append(UInt16(16).littleEndianData)
		data.append(contentsOf: "data".utf8)
		data.append(UInt32(dataSize).littleEndianData)

		let cueFrequencies = frequencies(isActive: isActive)
		let gains = isActive ? [0.20, 0.32, 0.45] : [0.45, 0.32, 0.20]
		var samples: [Double] = []
		samples.reserveCapacity(frameCount)
		for index in 0..<frameCount {
			let time = Double(index) / Double(sampleRate)
			let value = noteStarts.indices.reduce(0.0) { partialResult, noteIndex in
				partialResult + noteValue(
					time: time, start: noteStarts[noteIndex],
					frequency: cueFrequencies[noteIndex], gain: gains[noteIndex],
					softenEnding: isActive && noteIndex == noteStarts.count - 1
				)
			}
			samples.append(value)
		}
		data.append(samples.pcm(normalize: false))
		return data
	}

	private static func noteValue(time: Double, start: Double, frequency: Double, gain: Double, softenEnding: Bool) -> Double {
		let attack = 0.025
		let sustain = 0.10
		let decay = softenEnding ? 0.46 : 0.40
		let duration = attack + sustain + decay
		guard time >= start, time <= start + duration else {
			return 0
		}
		let localTime = time - start
		let envelope: Double
		if localTime <= attack {
			envelope = localTime / attack
		} else if localTime <= attack + sustain {
			envelope = 1
		} else {
			let decayProgress = (localTime - attack - sustain) / decay
			envelope = (1 + cos(Double.pi * decayProgress)) / 2
		}
		return sin(2 * Double.pi * frequency * localTime) * envelope * gain
	}

	private static func playHapticsIfNeeded(isActive: Bool, hapticsEnabled: Bool) {
		hapticTask?.cancel()
		guard hapticsEnabled else {
			hapticTask = nil
			return
		}
		hapticTask = Task { @MainActor in
			let intensities = isActive ? [0.25, 0.55, 0.9] : [0.9, 0.55, 0.25]
			let clock = ContinuousClock()
			let startTime = clock.now
			for (noteStart, intensity) in zip(noteStarts, intensities) {
				let targetTime = startTime + .milliseconds(Int(noteStart * 1_000))
				if clock.now < targetTime {
					try? await Task.sleep(until: targetTime, clock: clock)
				}
				guard !Task.isCancelled else { return }
				HapticFeedback().pulse(intensity: intensity)
			}
		}
	}
}

private extension Array where Element == Double {
	/// Preserve explicit note levels, or normalize the complete cue uniformly.
	func pcm(normalize: Bool = true) -> Data {
		let peak = normalize ? reduce(0.0) { Swift.max($0, abs($1)) } : 1.0
		let scale = peak > 0 ? Double(Int16.max) / peak : 0
		var data = Data(capacity: count * MemoryLayout<Int16>.size)
		for value in self {
			let sample = Int16(Swift.max(-Double(Int16.max), Swift.min(Double(Int16.max), value * scale)))
			data.append(sample.littleEndianData)
		}
		return data
	}

	func addingEcho(
		sampleRate: Int,
		taps: [(delay: Double, gain: Double)]
	) -> [Double] {
		var echoed = self
		for tap in taps {
			let delayFrames = Int(tap.delay * Double(sampleRate))
			guard delayFrames > 0 else {
				continue
			}
			for index in delayFrames..<count {
				echoed[index] += self[index - delayFrames] * tap.gain
			}
		}
		return echoed
	}
}

private struct WatchSettingsPayload {
	let areaMode: String
	let measurementUnit: String
	let directionStyle: String
	let spokenIntersectionCount: Int
	let includeAnnouncementDistance: Bool
	let includeAnnouncementDirection: Bool
	let includeAnnouncementNeighborhood: Bool
	let includeIntersectionDetails: Bool
	let includeCrossings: Bool
	let includeWalkingPaths: Bool
	let manhattanSnobMode: Bool

	var signature: String {
		[
			areaMode,
			measurementUnit,
			directionStyle,
			String(spokenIntersectionCount),
			String(includeAnnouncementDistance),
			String(includeAnnouncementDirection),
			String(includeAnnouncementNeighborhood),
			String(includeIntersectionDetails),
			String(includeCrossings),
			String(includeWalkingPaths),
			String(manhattanSnobMode)
		].joined(separator: "|")
	}

	var dictionary: [String: Any] {
		[
			"areaMode": areaMode,
			"measurementUnit": measurementUnit,
			"directionStyle": directionStyle,
			"spokenIntersectionCount": spokenIntersectionCount,
			"includeAnnouncementDistance": includeAnnouncementDistance,
			"includeAnnouncementDirection": includeAnnouncementDirection,
			"includeAnnouncementNeighborhood": includeAnnouncementNeighborhood,
			"includeIntersectionDetails": includeIntersectionDetails,
			"includeCrossings": includeCrossings,
			"includeWalkingPaths": includeWalkingPaths,
			"manhattanSnobMode": manhattanSnobMode
		]
	}
}

private final class WatchSettingsSync: NSObject, WCSessionDelegate {
	private let session: WCSession?
	private var pendingPayload: WatchSettingsPayload?

	override init() {
		if WCSession.isSupported() {
			session = WCSession.default
		} else {
			session = nil
		}
		super.init()
		session?.delegate = self
		session?.activate()
	}

	func sync(_ payload: WatchSettingsPayload) {
		pendingPayload = payload
		guard let session, session.activationState == .activated else {
			return
		}
		do {
			try session.updateApplicationContext(payload.dictionary)
		} catch {
			pendingPayload = payload
		}
	}

	func session(
		_ session: WCSession,
		activationDidCompleteWith activationState: WCSessionActivationState,
		error: Error?
	) {
		guard activationState == .activated, let pendingPayload else {
			return
		}
		sync(pendingPayload)
	}

	func sessionDidBecomeInactive(_ session: WCSession) {}

	func sessionDidDeactivate(_ session: WCSession) {
		session.activate()
	}
}

struct ContentView: View {
	@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
	@AppStorage("areaMode") private var areaModeRaw = AreaMode.near.rawValue
	@AppStorage("measurementUnit") private var measurementUnitRaw = MeasurementUnit.feet.rawValue
	@AppStorage("directionStyle") private var directionStyleRaw = DirectionStyle.words.rawValue
	@AppStorage("spokenIntersectionCount") private var spokenIntersectionCountRaw = SpokenIntersectionCount.one.rawValue
	@AppStorage("includeAnnouncementDistance") private var includeAnnouncementDistance = true
	@AppStorage("includeAnnouncementDirection") private var includeAnnouncementDirection = true
	@AppStorage("includeAnnouncementNeighborhood") private var includeAnnouncementNeighborhood = false
	@AppStorage("includeIntersectionDetails") private var includeIntersectionDetails = false
	@AppStorage("includeCrossings") private var includeCrossings = false
	@AppStorage("includeWalkingPaths") private var includeWalkingPaths = false
	@AppStorage("hapticsEnabled") private var hapticsEnabled = true
	@AppStorage("manhattanSnobMode") private var manhattanSnobMode = false
	@AppStorage("showRankedControls") private var showRankedControls = true
	@AppStorage("displayLayout") private var displayLayoutRaw = DisplayLayout.standard.rawValue
	@AppStorage(LiveModeAvailability.enabledKey) private var liveModeEnabled = true
	@AppStorage("liveTravelMode") private var liveTravelModeRaw = LiveTravelMode.walking.rawValue
	@AppStorage("liveStationaryMinutes") private var liveStationaryMinutes = 5.0
	@AppStorage("liveVoiceIdentifier") private var liveVoiceIdentifier = ""
	@AppStorage("liveSpeechRatePercent") private var liveSpeechRatePercent = 50
	@AppStorage("liveSpeechVolume") private var liveSpeechVolume = 1.0
	@AppStorage(LaunchKeys.liveModeCommand) private var liveModeShortcutCommandRaw = ""
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
	@Environment(\.openURL) private var openURL
	@Environment(\.scenePhase) private var scenePhase
	@ScaledMetric(relativeTo: .body) private var statusMinHeight: CGFloat = 112
	@ScaledMetric(relativeTo: .title2) private var actionMinHeight: CGFloat = 76
	@State private var statusText = startupLoadingText
	@State private var statusPresentationID = 0
	@State private var isStatusEmphasized = false
	@State private var hasMetMinimumStatusEmphasisDuration = true
	@State private var hasCurrentStatusOperationCompleted = true
	@State private var statusOperationID = 0
	@State private var statusEmphasisTask: Task<Void, Never>?
	@State private var isVisualLoadingIndicatorVisible = false
	@State private var visualLoadingIndicatorTask: Task<Void, Never>?
	@State private var isLoading = false
	@State private var isDirectionLoading = false
	@State private var isStartupLoading = false
	@State private var isMapPreparationLoading = false
	@State private var isMapDataReady = false
	@State private var isShowingSettings = false
	@State private var isShowingHelp = false
	@State private var isShowingMailComposer = false
	@State private var hasPreparedInitialLocation = false
	@State private var startupTask: Task<Void, Never>?
	@State private var startupAttemptID = UUID()
	@State private var hasPendingLiveModeStart = false
	@State private var onboardingLocationProvider = LocationProvider()
	@State private var directionLocationProvider = LocationProvider()
	@StateObject private var pointScanner = PointScanController()
	@StateObject private var liveMode = LiveModeCoordinator()
	@State private var scanPreparationStatusOperationID: Int?
	@State private var watchSettingsSync = WatchSettingsSync()
	private let mainActionBorderWidth: CGFloat = 3
	private let scanActionBorderWidth: CGFloat = 9

	private var prefs: AppPrefs {
		AppPrefs(
			areaMode: selectedAreaMode,
			measurementUnit: MeasurementUnit(rawValue: measurementUnitRaw) ?? .feet,
			directionStyle: DirectionStyle(rawValue: directionStyleRaw) ?? .words,
			intersectionWording: .direct,
			spokenIntersectionCount: SpokenIntersectionCount(rawValue: spokenIntersectionCountRaw) ?? .one,
			announcementOptions: AnnouncementOptions(
				includeDistance: includeAnnouncementDistance,
				includeDirection: includeAnnouncementDirection,
				includeNeighborhood: includeAnnouncementNeighborhood,
				includeIntersectionDetails: includeIntersectionDetails
			),
			mapDetails: MapDetailOptions(
				includeCrossings: includeCrossings,
				includeWalkingPaths: includeWalkingPaths
			),
			haptics: hapticsEnabled,
			manhattanSnobMode: manhattanSnobMode
		)
	}

	private var watchSettingsPayload: WatchSettingsPayload {
		WatchSettingsPayload(
			areaMode: selectedAreaMode.rawValue,
			measurementUnit: measurementUnitRaw,
			directionStyle: directionStyleRaw,
			spokenIntersectionCount: spokenIntersectionCountRaw,
			includeAnnouncementDistance: includeAnnouncementDistance,
			includeAnnouncementDirection: includeAnnouncementDirection,
			includeAnnouncementNeighborhood: includeAnnouncementNeighborhood,
			includeIntersectionDetails: includeIntersectionDetails,
			includeCrossings: includeCrossings,
			includeWalkingPaths: includeWalkingPaths,
			manhattanSnobMode: manhattanSnobMode
		)
	}

	private var displayLayout: DisplayLayout {
		DisplayLayout(rawValue: displayLayoutRaw) ?? .standard
	}

	private var selectedLiveTravelMode: LiveTravelMode {
		LiveTravelMode(rawValue: liveTravelModeRaw) ?? .walking
	}

	private var liveSpeechSettings: LiveSpeechSettings {
		LiveSpeechSettings(
			voiceIdentifier: liveVoiceIdentifier,
			ratePercent: liveSpeechRatePercent,
			volume: Float(liveSpeechVolume)
		)
	}

	private var liveSpeechRateBinding: Binding<Double> {
		Binding(
			get: { Double(liveSpeechRatePercent) },
			set: { liveSpeechRatePercent = Int($0.rounded()) }
		)
	}

	private var selectedAreaMode: AreaMode {
		let mode = AreaMode(rawValue: areaModeRaw) ?? .near
		return mode == .off ? .near : mode
	}

	private var mapReadinessSignature: String {
		"\(includeCrossings)-\(includeWalkingPaths)"
	}

	private var usesCenteredStatusLayout: Bool {
		displayLayout == .centered || dynamicTypeSize.isAccessibilitySize
	}

	var body: some View {
		Group {
			if hasCompletedOnboarding {
				mainView
			} else {
				OnboardingView(locationProvider: onboardingLocationProvider) {
					hasCompletedOnboarding = true
				}
			}
		}
		.tint(Color.crossAccent)
	}

	private var mainView: some View {
		NavigationStack {
			GeometryReader { geometry in
				ScrollView {
					VStack(spacing: 0) {
						statusView
						Group {
							if showRankedControls {
								rankedActionRow(
									primary: nearestButton,
									menu: rankedMenu(
										title: "More Nearest",
										actions: [
											("2nd", { await updateReport(.nearest, rank: 2) }),
											("3rd", { await updateReport(.nearest, rank: 3) })
										]
									)
								)
							} else {
								nearestButton
							}
						}
						.frame(minHeight: actionMinHeight)
						Group {
							if showRankedControls {
								rankedActionRow(
									primary: upcomingButton,
									menu: rankedMenu(
										title: "More Upcoming",
										actions: [
											("2nd", { await updateReport(.upcoming, rank: 2) }),
											("3rd", { await updateReport(.upcoming, rank: 3) })
										]
									)
								)
							} else {
								upcomingButton
							}
						}
						.frame(minHeight: actionMinHeight)
						actionButton(
							"Direction",
							systemImage: "safari.fill",
							accessibilityLabel: "My Direction",
							accessibilityHint: "Speaks cardinal direction.",
							isDisabled: isDirectionLoading || isStartupLoading
						) {
							await updateDirection()
						}
						.frame(minHeight: actionMinHeight)
						pointScanToggle
					}
					.frame(maxWidth: .infinity)
					.frame(minHeight: geometry.size.height, alignment: .top)
				}
			}
			.background(Color.crossBg)
			.navigationBarTitleDisplayMode(.inline)
			.navigationTitle("Intersector")
			.toolbarBackground(Color.crossBg, for: .navigationBar)
			.toolbarBackground(.visible, for: .navigationBar)
			.toolbar {
				ToolbarItemGroup(placement: .topBarTrailing) {
					if liveModeEnabled { liveToggle }
					settingsButton
				}
			}
			.sheet(isPresented: $isShowingSettings) {
				settingsView
			}
			.onAppear {
				if areaModeRaw == AreaMode.off.rawValue {
					areaModeRaw = AreaMode.near.rawValue
				}
				handleRequestedLiveModeCommandIfNeeded()
				if !startRequestedPointScanIfNeeded() {
					prepareInitialLocationIfNeeded()
				}
				watchSettingsSync.sync(watchSettingsPayload)
			}
			.onChange(of: watchSettingsPayload.signature) { _, _ in
				watchSettingsSync.sync(watchSettingsPayload)
			}
			.onChange(of: mapReadinessSignature) { _, _ in
				restartInitialPreparation()
			}
			.onChange(of: liveModeEnabled) { _, enabled in
				if !enabled {
					disableLiveMode()
				}
			}
			.onChange(of: liveMode.statusText) { _, text in
				presentStatusText(text)
			}
			.onChange(of: liveModeShortcutCommandRaw) { _, _ in
				handleRequestedLiveModeCommandIfNeeded()
			}
			.onChange(of: scenePhase) { _, phase in
				if phase == .active {
					handleRequestedLiveModeCommandIfNeeded()
					startPendingLiveModeIfReady()
				} else {
					pointScanner.stopScanning()
					finishScanPreparationPresentation()
				}
			}
		}
	}

	private var liveToggle: some View {
		Toggle("Live", isOn: liveModeBinding)
			.accessibilityAction(named: Text("Walking Mode")) { selectLiveMode(.walking) }
			.accessibilityAction(named: Text("Driving Mode")) { selectLiveMode(.driving) }
			.toggleStyle(.button)
			.tint(Color.crossAccent)
	}

	private var settingsButton: some View {
		Button("Settings") { isShowingSettings = true }
	}

	private var statusView: some View {
		VStack(spacing: 0) {
			Group {
				if usesCenteredStatusLayout {
					VStack(alignment: .center, spacing: 0) {
						currentInfoHeading(alignment: .center, isCentered: true)
						currentInfoBody(alignment: .center, textAlignment: .center)
					}
				} else {
					HStack(alignment: .top, spacing: 0) {
						currentInfoHeading(alignment: .leading, isCentered: false)
							.layoutPriority(1)
						currentInfoBody(alignment: .leading, textAlignment: .leading)
							.layoutPriority(2)
					}
				}
			}
		}
		.padding(.bottom, 56)
		.frame(maxWidth: .infinity, minHeight: statusMinHeight, alignment: usesCenteredStatusLayout ? .center : .topLeading)
		.background(Color.crossPanel)
		.overlay(alignment: .bottom) {
			visualLoadingIndicator
				.padding(.bottom, 8)
		}
		.overlay {
			Rectangle()
				.strokeBorder(Color.crossPanelAccent, lineWidth: 3)
				.padding(.bottom, 2)
				.opacity(isStatusEmphasized ? 1 : 0)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
		}
		.contentShape(Rectangle())
	}

	private func currentInfoHeading(
		alignment: Alignment,
		isCentered: Bool
	) -> some View {
		HStack(alignment: .center, spacing: 8) {
			Text("Current Info")
				.font(.title2)
				.fontWeight(.semibold)
				.foregroundStyle(.white)
				.lineLimit(1)
				.minimumScaleFactor(0.8)
				.fixedSize(horizontal: true, vertical: false)
				.accessibilityAddTraits(.isHeader)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.frame(maxWidth: isCentered ? .infinity : nil, minHeight: 60, alignment: alignment)
		.contentShape(Rectangle())
	}

	private func currentInfoText(
		alignment: Alignment,
		textAlignment: TextAlignment
	) -> some View {
		Text(statusText)
			.id(statusPresentationID)
			.font(.body)
			.foregroundStyle(Color.crossInv)
			.multilineTextAlignment(textAlignment)
			.lineLimit(nil)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.frame(maxWidth: .infinity, minHeight: 60, alignment: alignment)
			.contentShape(Rectangle())
			.transition(statusTextTransition)
			.animation(.easeInOut(duration: 0.24), value: statusPresentationID)
	}

	private func currentInfoBody(
		alignment: Alignment,
		textAlignment: TextAlignment
	) -> some View {
		currentInfoText(alignment: alignment, textAlignment: textAlignment)
	}

	private var statusTextTransition: AnyTransition {
		if accessibilityReduceMotion {
			return .opacity
		}
		return .asymmetric(
			insertion: .opacity.combined(with: .offset(y: 4)),
			removal: .opacity
		)
	}

	@ViewBuilder
	private var visualLoadingIndicator: some View {
		ZStack {
			if isVisualLoadingIndicatorVisible {
				ProgressView()
					.progressViewStyle(.circular)
					.tint(Color.crossPanelAccent)
					.controlSize(.large)
					.scaleEffect(1.25)
					.accessibilityHidden(true)
			} else {
				Color.clear
					.accessibilityHidden(true)
			}
		}
		.frame(maxWidth: .infinity)
		.frame(height: 48)
		.animation(.easeInOut(duration: 0.2), value: isVisualLoadingIndicatorVisible)
	}

	@discardableResult
	private func beginLoadingPresentation() -> Int {
		statusOperationID += 1
		let operationID = statusOperationID
		statusEmphasisTask?.cancel()
		visualLoadingIndicatorTask?.cancel()
		hasMetMinimumStatusEmphasisDuration = false
		hasCurrentStatusOperationCompleted = false
		isVisualLoadingIndicatorVisible = false
		withAnimation(.easeIn(duration: 0.2)) {
			isStatusEmphasized = true
		}

		statusEmphasisTask = Task { @MainActor in
			do {
				try await Task.sleep(for: .milliseconds(1_250))
			} catch {
				return
			}
			guard operationID == statusOperationID else {
				return
			}
			hasMetMinimumStatusEmphasisDuration = true
			guard hasCurrentStatusOperationCompleted else {
				return
			}
			fadeOutStatusEmphasis()
		}
		visualLoadingIndicatorTask = Task { @MainActor in
			do {
				try await Task.sleep(for: .seconds(2))
			} catch {
				return
			}
			guard
				operationID == statusOperationID,
				!hasCurrentStatusOperationCompleted
			else {
				return
			}
			withAnimation(.easeIn(duration: 0.2)) {
				isVisualLoadingIndicatorVisible = true
			}
		}
		return operationID
	}

	private func finishLoadingPresentation(operationID: Int) {
		guard operationID == statusOperationID else {
			return
		}
		hasCurrentStatusOperationCompleted = true
		visualLoadingIndicatorTask?.cancel()
		visualLoadingIndicatorTask = nil
		withAnimation(.easeOut(duration: 0.2)) {
			isVisualLoadingIndicatorVisible = false
		}
		guard hasMetMinimumStatusEmphasisDuration else {
			return
		}
		fadeOutStatusEmphasis()
	}

	private func fadeOutStatusEmphasis() {
		withAnimation(.easeOut(duration: 0.35)) {
			isStatusEmphasized = false
		}
		statusEmphasisTask = nil
	}

	private var nearestButton: some View {
		actionButton(
			"Nearest",
			systemImage: "location.fill",
			accessibilityLabel: "Nearest Intersection",
			isDisabled: isLoading || isStartupLoading || isMapPreparationLoading || pointScanner.isScanning || pointScanner.isPreparing,
			drawsChrome: !showRankedControls,
			isVisuallyDimmed: pointScanner.isScanning || pointScanner.isPreparing
		) {
			await updateReport(.nearest)
		}
		.accessibilityAction(named: Text("3rd Nearest Intersection")) {
			Task {
				await updateReport(.nearest, rank: 3)
			}
		}
		.accessibilityAction(named: Text("2nd Nearest Intersection")) {
			Task {
				await updateReport(.nearest, rank: 2)
			}
		}
	}

	private var upcomingButton: some View {
		actionButton(
			"Upcoming",
			systemImage: "arrow.up.circle.fill",
			accessibilityLabel: "Upcoming Intersection",
			isDisabled: isLoading || isStartupLoading || isMapPreparationLoading || pointScanner.isScanning || pointScanner.isPreparing,
			drawsChrome: !showRankedControls,
			isVisuallyDimmed: pointScanner.isScanning || pointScanner.isPreparing
		) {
			await updateReport(.upcoming)
		}
		.accessibilityAction(named: Text("3rd Upcoming Intersection")) {
			Task {
				await updateReport(.upcoming, rank: 3)
			}
		}
		.accessibilityAction(named: Text("2nd Upcoming Intersection")) {
			Task {
				await updateReport(.upcoming, rank: 2)
			}
		}
	}

	private var pointScanToggle: some View {
		Button {
			toggleScanMode()
		} label: {
			actionLabel("Scan", systemImage: "dot.radiowaves.left.and.right")
				.frame(maxWidth: .infinity, minHeight: actionMinHeight, alignment: .center)
				.contentShape(Rectangle())
		}
		.buttonStyle(PersistentScanButtonStyle())
		.frame(maxWidth: .infinity, minHeight: actionMinHeight, alignment: .center)
		.foregroundStyle(Color.crossButtonText)
		.background(pointScanBackground)
		.overlay(Rectangle().stroke(Color.crossButtonStrongBorder, lineWidth: scanActionBorderWidth))
		.shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
		.contentShape(Rectangle())
		.disabled(isLoading || isStartupLoading)
		.accessibilityValue(pointScanner.isScanning || pointScanner.isPreparing ? "On" : "Off")
		.accessibilityAddTraits(pointScanner.isScanning || pointScanner.isPreparing ? .isSelected : [])
	}

	private var pointScanBackground: Color {
		pointScanner.isScanning || pointScanner.isPreparing ? Color.crossScanActive : Color.crossScanIdle
	}

	private func rankedActionRow(
		primary: some View,
		menu: some View
	) -> some View {
		let isVisuallyDimmed = pointScanner.isScanning || pointScanner.isPreparing
		return ZStack(alignment: .trailing) {
			primary
				.frame(maxWidth: .infinity)
			menu
				.frame(width: 48, alignment: .center)
		}
		.background(Color.crossBtn.opacity(isVisuallyDimmed ? 0.72 : 1))
		.overlay(
			Rectangle().stroke(
				Color.crossButtonStrongBorder.opacity(isVisuallyDimmed ? 0.72 : 1),
				lineWidth: mainActionBorderWidth
			)
		)
		.shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
		.contentShape(Rectangle())
	}

	private func rankedMenu(
		title: String,
		actions: [(String, () async -> Void)]
	) -> some View {
		Menu {
			ForEach(actions, id: \.0) { action in
				Button(action.0) {
					Task {
						await action.1()
					}
				}
			}
		} label: {
			Image(systemName: "chevron.down")
				.imageScale(.medium)
				.frame(width: 48)
				.frame(minHeight: actionMinHeight)
				.foregroundStyle(Color.crossChevron)
				.contentShape(Rectangle())
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.disabled(isLoading || isStartupLoading || isMapPreparationLoading || pointScanner.isScanning || pointScanner.isPreparing)
		.accessibilityHidden(true)
	}

	private var areaModeBinding: Binding<AreaMode> {
		Binding {
			selectedAreaMode
		} set: { areaMode in
			areaModeRaw = areaMode.rawValue
		}
	}

	private var liveTravelModeBinding: Binding<LiveTravelMode> {
		Binding {
			selectedLiveTravelMode
		} set: { mode in
			liveTravelModeRaw = mode.rawValue
		}
	}

	private var liveModeBinding: Binding<Bool> {
		Binding {
			liveMode.isActive
		} set: { shouldStart in
			setLiveMode(shouldStart)
		}
	}

	private var measurementUnitBinding: Binding<MeasurementUnit> {
		Binding {
			prefs.measurementUnit
		} set: { measurementUnit in
			measurementUnitRaw = measurementUnit.rawValue
		}
	}

	private var directionStyleBinding: Binding<DirectionStyle> {
		Binding {
			prefs.directionStyle
		} set: { directionStyle in
			directionStyleRaw = directionStyle.rawValue
		}
	}

	private var announcementDistanceBinding: Binding<Bool> {
		Binding {
			includeAnnouncementDistance
		} set: { isEnabled in
			includeAnnouncementDistance = isEnabled
		}
	}

	private var announcementDirectionBinding: Binding<Bool> {
		Binding {
			includeAnnouncementDirection
		} set: { isEnabled in
			includeAnnouncementDirection = isEnabled
		}
	}

	private var announcementNeighborhoodBinding: Binding<Bool> {
		Binding {
			includeAnnouncementNeighborhood
		} set: { isEnabled in
			if isEnabled, areaModeRaw == AreaMode.off.rawValue {
				areaModeRaw = AreaMode.near.rawValue
			}
			includeAnnouncementNeighborhood = isEnabled
		}
	}

	private var intersectionDetailsBinding: Binding<Bool> {
		Binding {
			includeIntersectionDetails
		} set: { isEnabled in
			includeIntersectionDetails = isEnabled
		}
	}

	private var announcementSampleText: String {
		let report = OrientReport(
			kind: .nearest,
			cross: includeCrossings
				? "Crossing on Amsterdam Avenue near West 94th Street"
				: "Amsterdam Avenue and West 94th Street",
			dist: "120 feet",
			relDir: "ahead",
			relDegrees: 0,
			street: "Amsterdam Avenue",
			crossStreet: nil,
			head: "north",
			area: "Upper West Side",
			toward: "Manhattan Valley",
			conf: .high,
			intersectionDetails: IntersectionDetails(
				isSignalized: true,
				hasPedestrianIsland: true,
				isStreetIntersection: !includeCrossings
			)
		)
		return report.text(with: prefs)
	}



	private var rankedControlsBinding: Binding<Bool> {
		Binding {
			showRankedControls
		} set: { isEnabled in
			showRankedControls = isEnabled
		}
	}

	private var displayLayoutBinding: Binding<DisplayLayout> {
		Binding {
			displayLayout
		} set: { layout in
			displayLayoutRaw = layout.rawValue
		}
	}

	private var spokenIntersectionCountBinding: Binding<SpokenIntersectionCount> {
		Binding {
			prefs.spokenIntersectionCount
		} set: { count in
			spokenIntersectionCountRaw = count.rawValue
		}
	}

	private func spokenIntersectionOptionAccessibilityLabel(_ count: SpokenIntersectionCount) -> String {
		switch count {
		case .one:
			"1 intersection"
		case .two:
			"2 intersections"
		case .three:
			"3 intersections"
		}
	}

	private var hapticsBinding: Binding<Bool> {
		Binding {
			hapticsEnabled
		} set: { isEnabled in
			hapticsEnabled = isEnabled
		}
	}

	private var manhattanSnobModeBinding: Binding<Bool> {
		Binding {
			manhattanSnobMode
		} set: { isEnabled in
			manhattanSnobMode = isEnabled
		}
	}

	private var crossingsBinding: Binding<Bool> {
		Binding {
			includeCrossings
		} set: { isEnabled in
			includeCrossings = isEnabled
		}
	}

	private var walkingPathsBinding: Binding<Bool> {
		Binding {
			includeWalkingPaths
		} set: { isEnabled in
			includeWalkingPaths = isEnabled
		}
	}

	private var settingsView: some View {
		NavigationStack {
			GeometryReader { geometry in
				ScrollView {
					settingsContent
						.frame(maxWidth: .infinity)
						.frame(minHeight: geometry.size.height, alignment: .top)
				}
			}
			.background(Color.crossBg)
			.tint(Color.crossAccent)
			.navigationTitle("")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") {
						isShowingSettings = false
					}
				}
			}
			.sheet(isPresented: $isShowingMailComposer) {
				MailComposerView(
					recipient: "marco@marconius.com",
					subject: "Intersector Feedback",
					body: feedbackEmailBody,
					onFinish: { _ in }
				)
			}
			.sheet(isPresented: $isShowingHelp) {
				helpView
			}
		}
	}

	private var settingsContent: some View {
		VStack(alignment: .leading, spacing: 0) {
			settingsIntroSection
			settingsDisplaySection
			settingsAnnouncementSection
			settingsRegionalWordingSection
			settingsMapDetailSection
			settingsInteractionSection
			settingsLiveModeSection
			settingsAboutSection
		}
		.frame(maxHeight: .infinity)
	}

	private var settingsLiveModeSection: some View {
		Group {
			settingsHeader("Live Mode")
			settingsControlRow {
				Toggle("Live Mode", isOn: $liveModeEnabled)
					.tint(Color.crossControlTint)
			}
			if liveModeEnabled {
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Text("Travel Mode")
							.foregroundStyle(Color.crossText)
						Picker("Travel Mode", selection: liveTravelModeBinding) {
							ForEach(LiveTravelMode.allCases) { mode in
								Text(mode.label).tag(mode)
							}
						}
						.pickerStyle(.segmented)
					}
				}
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Text("Stop When Stationary: \(Int(liveStationaryMinutes.rounded())) minutes")
							.foregroundStyle(Color.crossText)
							.accessibilityHidden(true)
						Slider(
							value: $liveStationaryMinutes,
							in: 5...30,
							step: 1,
							label: { Text("Stop When Stationary, \(Int(liveStationaryMinutes.rounded())) minutes") }
						)
						.tint(Color.crossControlTint)
					}
				}
				settingsHeader("System Speech")
				settingsControlRow {
					LiveVoicePicker(voiceIdentifier: $liveVoiceIdentifier)
				}
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Text("Speech Rate: \(liveSpeechRatePercent) percent")
							.foregroundStyle(Color.crossText)
							.accessibilityHidden(true)
						Slider(
							value: liveSpeechRateBinding,
							in: 0...100,
							step: 5,
							label: { Text("Speech Rate") }
						)
						.tint(Color.crossControlTint)
					}
				}
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Text("Speech Volume")
							.foregroundStyle(Color.crossText)
							.accessibilityHidden(true)
						Slider(
							value: $liveSpeechVolume,
							in: 0...1,
							label: { Text("Speech Volume") }
						)
						.tint(Color.crossControlTint)
					}
				}
				settingsControlRow {
					Button {
						SystemSpeechController.shared.speak(
							"Welcome to Intersector!",
							settings: liveSpeechSettings
						)
					} label: {
						settingsButtonLabel("Test Speech")
					}
					.buttonStyle(.plain)
				}
			}
		}
	}

	private var settingsIntroSection: some View {
		Group {
			settingsTitleRow
		}
	}

	private var settingsTitleRow: some View {
		ViewThatFits(in: .horizontal) {
			HStack(alignment: .center, spacing: 12) {
				settingsTitle
					.fixedSize(horizontal: true, vertical: false)
				Spacer(minLength: 0)
				helpButton
					.fixedSize(horizontal: true, vertical: false)
			}
			VStack(alignment: .leading, spacing: 0) {
				settingsTitle
					.frame(maxWidth: .infinity, alignment: .leading)
				helpButton
					.frame(maxWidth: .infinity, alignment: .trailing)
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
		.background(Color.crossSettingsHeader)
		.contentShape(Rectangle())
	}

	private var settingsTitle: some View {
		Text("Settings")
			.font(.largeTitle)
			.fontWeight(.bold)
			.foregroundStyle(Color.crossText)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityAddTraits(.isHeader)
	}

	private var helpButton: some View {
		Button {
			isShowingHelp = true
		} label: {
			Text("Help")
				.font(.body)
				.fontWeight(.semibold)
				.foregroundStyle(Color.crossAccent)
				.multilineTextAlignment(.center)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.horizontal, 14)
				.padding(.vertical, 6)
				.frame(minWidth: 72, minHeight: 52, alignment: .center)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityHint("Opens instructions for using Intersector.")
	}

	private var settingsDisplaySection: some View {
		Group {
			settingsHeader("Display")
			settingsControlRow {
				VStack(alignment: .leading, spacing: 8) {
					Text("Current Info Layout")
						.foregroundStyle(Color.crossText)
					Picker("Current Info Layout", selection: displayLayoutBinding) {
						ForEach(DisplayLayout.allCases) { layout in
							Text(layout.label).tag(layout)
						}
					}
					.pickerStyle(.segmented)
				}
			}
			settingsControlRow {
				Toggle("Show 2nd and 3rd Controls", isOn: rankedControlsBinding)
					.tint(Color.crossControlTint)
					.accessibilityHint("Toggles the visibility of the menu chevrons")
			}
		}
	}

	private var settingsAnnouncementSection: some View {
		Group {
			settingsHeader("Spoken Announcements")
			settingsControlRow {
				Toggle("Distance", isOn: announcementDistanceBinding)
					.tint(Color.crossControlTint)
			}
			if includeAnnouncementDistance {
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Picker("Measurement Unit", selection: measurementUnitBinding) {
							ForEach(MeasurementUnit.allCases) { item in
								Text(item.label).tag(item)
							}
						}
						.pickerStyle(.segmented)
					}
				}
			}
			settingsControlRow {
				Toggle("Direction", isOn: announcementDirectionBinding)
					.tint(Color.crossControlTint)
			}
			if includeAnnouncementDirection {
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Picker("Direction Style", selection: directionStyleBinding) {
							ForEach(DirectionStyle.allCases) { item in
								Text(directionStyleSegmentLabel(item))
									.accessibilityLabel(directionStyleSegmentAccessibilityLabel(item))
									.tag(item)
							}
						}
						.pickerStyle(.segmented)
					}
				}
			}
			settingsControlRow {
				Toggle("Neighborhood", isOn: announcementNeighborhoodBinding)
					.tint(Color.crossControlTint)
			}
			if includeAnnouncementNeighborhood {
				settingsControlRow {
					VStack(alignment: .leading, spacing: 8) {
						Picker("Neighborhood Context", selection: areaModeBinding) {
							ForEach(AreaMode.selectableCases) { mode in
								Text(areaModeSegmentLabel(mode))
									.accessibilityLabel(areaModeSegmentAccessibilityLabel(mode))
									.tag(mode)
							}
						}
						.pickerStyle(.segmented)
					}
				}
			}
			settingsControlRow {
				Toggle("Intersection Details", isOn: intersectionDetailsBinding)
					.tint(Color.crossControlTint)
			}
			settingsControlRow {
				spokenIntersectionsControl
			}
			sampleAnnouncementSection
		}
	}

	private var sampleAnnouncementSection: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Sample Announcement")
				.font(.headline)
				.fontWeight(.bold)
				.foregroundStyle(Color.crossText)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.horizontal, 16)
				.padding(.top, 12)
				.padding(.bottom, 6)
				.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
				.contentShape(Rectangle())
				.accessibilityAddTraits(.isHeader)
			Text(announcementSampleText)
				.font(.footnote)
				.foregroundStyle(Color.crossText)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.horizontal, 16)
				.padding(.top, 4)
				.padding(.bottom, 12)
				.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
				.contentShape(Rectangle())
		}
		.background(Color.crossSettingsHelper)
	}

	private var settingsRegionalWordingSection: some View {
		Group {
			settingsHeader("Regional Wording")
			settingsControlRow {
				Toggle("Manhattan Snob Mode", isOn: manhattanSnobModeBinding)
					.tint(Color.crossControlTint)
			}
		}
	}

	private var spokenIntersectionsControl: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Spoken Intersections")
				.foregroundStyle(Color.crossText)
			Picker("Spoken Intersections", selection: spokenIntersectionCountBinding) {
				ForEach(SpokenIntersectionCount.allCases) { count in
					Text(count.label)
						.accessibilityLabel(spokenIntersectionOptionAccessibilityLabel(count))
						.tag(count)
				}
			}
			.pickerStyle(.segmented)
		}
	}

	private var settingsMapDetailSection: some View {
		Group {
			settingsHeader("Map Data")
			settingsControlRow {
				Toggle("Include crossings", isOn: crossingsBinding)
					.tint(Color.crossControlTint)
			}
			settingsControlRow {
				Toggle("Include walking paths", isOn: walkingPathsBinding)
					.tint(Color.crossControlTint)
			}
		}
	}

	private var settingsInteractionSection: some View {
		Group {
			settingsHeader("Interaction")
			settingsControlRow {
				Toggle("Haptic scan feedback", isOn: hapticsBinding)
					.tint(Color.crossControlTint)
			}
		}
	}

	private var settingsAboutSection: some View {
		Group {
			settingsHeader("About Intersector")
			settingsControlRow {
				Button {
					if MFMailComposeViewController.canSendMail() {
						isShowingMailComposer = true
					} else {
						openMailFallback()
					}
				} label: {
					settingsButtonLabel("Send Intersector Feedback")
				}
				.buttonStyle(.plain)
				.accessibilityHint("Opens Mail so you can send feedback about Intersector.")
			}
			settingsControlRow {
				externalLink(title: "Privacy Policy", url: "https://marconius.com/csPrivacy/")
			}
			settingsControlRow {
				AcknowledgementsSettingsButton()
			}
			settingsControlRow {
				Text(appFooterText)
					.font(.footnote)
					.multilineTextAlignment(.center)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .center)
					.foregroundStyle(Color.crossText)
			}
		}
	}

	private var helpView: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					Text("Intersector helps you identify nearby intersections, find the direction your phone is facing, and get street information through the app, Siri, Shortcuts, or Apple Watch.")
						.font(.body)
						.foregroundStyle(Color.crossText)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)

					helpSection(
						title: "Nearest Intersection",
						paragraphs: [
							"Use Nearest to find the intersection closest to your current location."
						]
					)

					helpSection(
						title: "Upcoming Intersection",
						paragraphs: [
							"Use Upcoming to find the next intersection along your current road in the direction your phone is facing."
						]
					)

					helpSection(
						title: "2nd and 3rd Results",
						paragraphs: [
							"Use the menus beside Nearest and Upcoming to choose the second or third result.",
							"With VoiceOver, choose the second or third intersection from the button’s Actions menu.",
							"Use Show 2nd and 3rd Controls in Settings to show or hide these menus."
						]
					)

					helpSection(
						title: "My Direction",
						paragraphs: [
							"Use Direction to hear the direction your phone is facing, such as north or southwest."
						]
					)

					helpSection(
						title: "Scan",
						paragraphs: [
							"Turn on Scan and point the top of your phone around you to identify nearby intersections and crossings. Intersector announces a result when your phone lines up with it.",
							"Scan uses the location where you turned it on. Stay at that location while scanning.",
							"Turn Scan off before moving to a new location. Once you arrive, turn it on again to scan from there.",
							"Vibration gets stronger as you point toward a result. Use Haptic scan feedback in Settings to turn vibration on or off."
						]
					)

					helpSection(
						title: "Current Info Layout",
						paragraphs: [
							"Choose Default to place the heading beside the announcement, or Centered to place it above the announcement."
						]
					)

					helpSection(
						title: "Announcement Options",
						paragraphs: [
							"Distance adds the approximate distance to an intersection. Use Measurement Unit to choose feet or meters.",
							"Direction adds the direction of an intersection. Choose Relative for ahead, left, and right; Cardinal for north, south, east, and west; or Clock Face for positions such as 10 o’clock.",
							"Neighborhood adds the nearby area. Choose Toward to also include the area ahead.",
							"Intersection Details adds mapped traffic signals and pedestrian islands.",
							"Spoken Intersections chooses one, two, or three results per announcement."
						]
					)

					helpSection(
						title: "Manhattan Snob Mode",
						paragraphs: [
							"Use Uptown, Downtown, East Side, and West Side for spoken compass directions."
						]
					)

					helpSection(
						title: "Map Options",
						paragraphs: [
							"Include crossings adds mapped crossings on named roads.",
							"Include walking paths adds named paths and their intersections."
						]
					)

					helpSection(
						title: "Live Mode",
						paragraphs: [
							"Turn on Live to hear upcoming intersections as you travel, including while the phone is locked.",
							"Live Mode in Settings shows or hides Live on the home screen.",
							"Choose Walking for travel on foot or Driving for travel by car or bus. Driving announces intersections sooner.",
							"Driving turns Live off when you enter a highway; turn Live back on after leaving the highway.",
							"Stop When Stationary sets how long Live continues after you stop moving.",
							"Choose a voice, Speech Rate, and Speech Volume for Live announcements. Use Test Speech to hear your selections."
						]
					)

					helpSection(
						title: "Siri and Shortcuts",
						paragraphs: [
							"Use Siri or Shortcuts for Nearest Intersection, Upcoming Intersection, My Direction, Scan Mode, Start Live Mode, and Stop Live Mode.",
							"To start Live with Siri or Shortcuts, turn on Live Mode in Settings and choose your travel and speech settings.",
							"Use the Shortcuts app to create your own phrases."
						]
					)

					helpSection(
						title: "Apple Watch",
						paragraphs: [
							"Use Intersector on your watch for Nearest, Upcoming, Direction, and second and third results.",
							"Change announcement settings on your iPhone to use them on your watch."
						]
					)

					helpSection(
						title: "Accuracy",
						paragraphs: [
							"Directions and distances are estimates.",
							"Location accuracy, compass accuracy, and map coverage affect results.",
							"Tall buildings, magnetic interference, and missing or outdated map information can affect the announcements."
						]
					)
				}
				.padding(24)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.scrollContentBackground(.hidden)
			.background(Color.crossBg)
			.navigationTitle("Help")
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button("Done") {
						isShowingHelp = false
					}
				}
			}
		}
		.tint(Color.crossAccent)
	}

	private func helpSection(title: String, paragraphs: [String]) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title)
				.font(.headline)
				.foregroundStyle(Color.crossText)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityAddTraits(.isHeader)
			ForEach(paragraphs.indices, id: \.self) { index in
				Text(paragraphs[index])
					.font(.body)
					.foregroundStyle(Color.crossText)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private func directionStyleSegmentLabel(_ style: DirectionStyle) -> String {
		switch style {
		case .words:
			"Relative"
		case .cardinal:
			"Cardinal"
		case .clockFace:
			"Clock"
		}
	}

	private func directionStyleSegmentAccessibilityLabel(_ style: DirectionStyle) -> String {
		switch style {
		case .words:
			"Relative direction"
		case .cardinal:
			"Cardinal direction"
		case .clockFace:
			"Clock face direction"
		}
	}

	private func areaModeSegmentLabel(_ mode: AreaMode) -> String {
		switch mode {
		case .off:
			"Off"
		case .near:
			"Nearby"
		case .toward:
			"Toward"
		}
	}

	private func areaModeSegmentAccessibilityLabel(_ mode: AreaMode) -> String {
		switch mode {
		case .off:
			"Off"
		case .near:
			"Nearby only"
		case .toward:
			"Toward, includes nearby and toward areas"
		}
	}

	private func settingsHeader(_ title: String) -> some View {
		Text(title)
			.font(.title3)
			.fontWeight(.bold)
			.foregroundStyle(Color.crossText)
			.textCase(nil)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 16)
			.padding(.top, 14)
			.padding(.bottom, 8)
			.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
			.background(Color.crossSettingsHeader)
			.contentShape(Rectangle())
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(title)
			.accessibilityAddTraits(.isHeader)
	}



	private func settingsControlRow<Content: View>(
		@ViewBuilder content: () -> Content
	) -> some View {
		content()
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
			.background(Color.crossSettingsRow)
			.overlay(alignment: .bottom) {
				Rectangle()
					.fill(Color.crossSettingsDivider)
					.frame(height: 1)
			}
			.contentShape(Rectangle())
	}

	private func settingsButtonLabel(_ title: String) -> some View {
		Text(title)
			.font(.body)
			.fontWeight(.semibold)
			.foregroundStyle(Color.crossAccent)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
	}

	private func actionButton(
		_ title: String,
		systemImage: String,
		accessibilityLabel: String? = nil,
		accessibilityHint: String? = nil,
		isDisabled: Bool? = nil,
		drawsChrome: Bool = true,
		isVisuallyDimmed: Bool = false,
		action: @escaping () async -> Void
	) -> some View {
		let disabled = isDisabled ?? (isLoading || isStartupLoading || pointScanner.isScanning || pointScanner.isPreparing)
		let buttonFill = drawsChrome ? Color.crossBtn.opacity(isVisuallyDimmed ? 0.72 : 1) : Color.clear
		let buttonBorder = drawsChrome ? Color.crossButtonStrongBorder.opacity(isVisuallyDimmed ? 0.72 : 1) : Color.clear
		return Button {
			Task {
				await action()
			}
		} label: {
			actionLabel(title, systemImage: systemImage)
				.frame(maxWidth: .infinity, minHeight: actionMinHeight, alignment: .center)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.frame(maxWidth: .infinity)
		.foregroundStyle(Color.crossButtonText)
		.background(buttonFill)
		.overlay(Rectangle().stroke(buttonBorder, lineWidth: mainActionBorderWidth))
		.shadow(color: drawsChrome ? Color.black.opacity(0.18) : Color.clear, radius: 2, x: 0, y: 1)
		.contentShape(Rectangle())
		.disabled(disabled)
		.accessibilityLabel(accessibilityLabel ?? title)
		.accessibilityHint(accessibilityHint ?? "")
	}

	private func externalLink(title: String, url: String) -> some View {
		Link(title, destination: URL(string: url)!)
			.font(.body)
			.foregroundStyle(Color.crossAccent)
			.underline()
			.accessibilityTouchRegion(minHeight: 60, verticalPadding: 4, alignment: .leading)
			.accessibilityAddTraits(.isLink)
			.accessibilityRemoveTraits(.isButton)
			.accessibilityHint("Opens in external browser")
	}


	private func actionLabel(_ title: String, systemImage: String) -> some View {
		Label {
			Text(title)
				.multilineTextAlignment(.center)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
		} icon: {
			Image(systemName: systemImage)
		}
		.font(.title2)
		.fontWeight(.semibold)
		.labelStyle(.titleAndIcon)
		.padding(12)
	}

	private func presentStatusText(_ text: String) {
		guard text != statusText else {
			return
		}

		statusText = text
		statusPresentationID += 1
	}

	private func handleScanModeStatus(_ text: String) {
		guard text != "Scan Mode Loading..." else {
			return
		}
		let completedPreparation = finishScanPreparationPresentation()
		if !completedPreparation, pointScanner.isScanning {
			let operationID = beginLoadingPresentation()
			finishLoadingPresentation(operationID: operationID)
		}
		presentStatusText(text)
	}

	private func toggleScanMode() {
		let isStopping = pointScanner.isScanning || pointScanner.isPreparing
		let operationID = beginLoadingPresentation()
		if isStopping {
			scanPreparationStatusOperationID = nil
			pointScanner.setScanning(false, prefs: prefs) { text in
				handleScanModeStatus(text)
			}
			finishLoadingPresentation(operationID: operationID)
			return
		}

		if liveMode.isActive {
			liveMode.stop()
		}
		scanPreparationStatusOperationID = operationID
		pointScanner.setScanning(true, prefs: prefs) { text in
			handleScanModeStatus(text)
		}
	}

	private func disableLiveMode() {
		hasPendingLiveModeStart = false
		liveModeShortcutCommandRaw = ""
		if liveMode.isActive {
			liveMode.stop()
		}
	}

	private func selectLiveMode(_ mode: LiveTravelMode) {
		guard liveModeEnabled else { return }
		liveTravelModeRaw = mode.rawValue
		if liveMode.isActive {
			liveMode.switchMode(to: mode)
		} else {
			setLiveMode(true)
		}
	}

	private func setLiveMode(_ shouldStart: Bool) {
		if !shouldStart {
			hasPendingLiveModeStart = false
			liveMode.stop()
			return
		}

		guard liveModeEnabled else {
			disableLiveMode()
			return
		}

		if pointScanner.isScanning || pointScanner.isPreparing {
			scanPreparationStatusOperationID = nil
			pointScanner.setScanning(false, prefs: prefs) { _ in }
			finishScanPreparationPresentation()
		}
		liveMode.start(
			mode: selectedLiveTravelMode,
			prefs: prefs,
			speechSettings: liveSpeechSettings,
			stationaryMinutes: liveStationaryMinutes
		)
	}

	private func handleRequestedLiveModeCommandIfNeeded() {
		guard let command = LiveModeShortcutCommand(rawValue: liveModeShortcutCommandRaw) else {
			return
		}
		liveModeShortcutCommandRaw = ""

		switch command {
		case .start:
			guard liveModeEnabled else {
				disableLiveMode()
				presentStatusText(LiveModeAvailability.disabledMessage)
				return
			}
			hasPendingLiveModeStart = true
			if pointScanner.isScanning || pointScanner.isPreparing {
				scanPreparationStatusOperationID = nil
				pointScanner.setScanning(false, prefs: prefs) { _ in }
				finishScanPreparationPresentation()
			}
			if !isMapDataReady {
				prepareInitialLocationIfNeeded()
			}
			startPendingLiveModeIfReady()
		case .stop:
			hasPendingLiveModeStart = false
			if liveMode.isActive {
				setLiveMode(false)
			}
		}
	}

	private func startPendingLiveModeIfReady() {
		guard liveModeEnabled else {
			disableLiveMode()
			return
		}
		guard hasPendingLiveModeStart, isMapDataReady, scenePhase == .active else {
			return
		}
		hasPendingLiveModeStart = false
		setLiveMode(true)
	}

	@discardableResult
	private func finishScanPreparationPresentation() -> Bool {
		guard let operationID = scanPreparationStatusOperationID else {
			return false
		}
		scanPreparationStatusOperationID = nil
		finishLoadingPresentation(operationID: operationID)
		return true
	}

	private func updateReport(_ kind: ReportKind, rank: Int = 1) async {
		guard !isLoading else { return }
		cancelStartupPreparationIfNeeded()
		let operationID = beginLoadingPresentation()
		let requestPrefs = prefs
		let service = OrientSvc.interactiveSession()
		isLoading = true
		let loadingTask = Task { @MainActor in
			do {
				try await Task.sleep(for: .seconds(2))
				LoadingThrobber.start(hapticsEnabled: requestPrefs.haptics)
				VoiceOverAnnouncer.statusUpdated(lookupLoadingText)
				try await Task.sleep(for: .seconds(8))
				VoiceOverAnnouncer.statusUpdated(extendedLookupLoadingText)
			} catch {}
		}
		defer {
			loadingTask.cancel()
			LoadingThrobber.stop()
			isLoading = false
			finishLoadingPresentation(operationID: operationID)
		}
		do {
			let text = try await LookupAttempt.run {
				if rank == 1 {
					return try await service.spokenText(kind, prefs: requestPrefs)
				}
				return try await service.report(kind, rank: rank, prefs: requestPrefs).text(with: requestPrefs, rank: rank)
			}
			try Task.checkCancellation()
			isMapDataReady = true
			presentStatusText(text)
			VoiceOverAnnouncer.reportUpdated(text)
		} catch {
			guard !Task.isCancelled else { return }
			let text = reportFailureText(kind, rank: rank, error: error)
			presentStatusText(text)
			VoiceOverAnnouncer.reportUpdated(text)
		}
	}

	private func reportFailureText(_ kind: ReportKind, rank: Int, error: Error) -> String {
		if case MapDataError.serversCoolingDown = error {
			return "Map services are temporarily busy. Please wait a minute, then choose Nearest or Upcoming to try again."
		}
		if let locationError = error as? CLError {
			return locationError.code == .denied
				? "Allow Intersector to use your location in iPhone Settings, then choose Nearest or Upcoming to try again."
				: "Intersector could not get your location yet. Choose Nearest or Upcoming to try again."
		}
		if rank > 1 {
			return "Intersector could not find the \(rankedFailureLabel(kind, rank: rank)). Please try again."
		}
		if let orientError = error as? OrientError {
			switch orientError {
			case .noIntersections where kind == .upcoming:
				return "Intersector could not identify an Upcoming intersection for that direction. Please try again."
			case .headingUnavailable:
				return "Intersector could not get a stable direction yet. Please try again."
			case .locationUnavailable:
				return "Intersector could not get your location yet. Please try again."
			default:
				break
			}
		}
		return "Intersector is having trouble loading map data. Choose Nearest or Upcoming to try again."
	}

	private func rankedFailureLabel(_ kind: ReportKind, rank: Int) -> String {
		switch kind {
		case .nearest:
			return "\(ordinal(rank)) Nearest intersection"
		case .upcoming:
			return "\(ordinal(rank)) Upcoming intersection"
		case .scan:
			return "\(ordinal(rank)) Pointed intersection"
		}
	}

	private func reportLabel(_ kind: ReportKind, rank: Int) -> String {
		guard rank > 1 else {
			return kind.intentLabel
		}
		return "\(ordinal(rank)) \(kind.intentLabel)"
	}

	private func ordinal(_ value: Int) -> String {
		switch value {
		case 2:
			"2nd"
		case 3:
			"3rd"
		default:
			"\(value)th"
		}
	}

	private func updateDirection() async {
		guard !isDirectionLoading else {
			return
		}
		let operationID = beginLoadingPresentation()
		isDirectionLoading = true
		defer {
			isDirectionLoading = false
			finishLoadingPresentation(operationID: operationID)
		}

		do {
			let heading = try await directionLocationProvider.currentHeading(allowCached: false)
			let text = "Facing \(Geo.localizedDirection(heading, prefs: prefs))."
			presentStatusText(text)
			VoiceOverAnnouncer.reportUpdated(text)
		} catch {
			let text = "Intersector is having trouble getting your direction. Please try again."
			presentStatusText(text)
			VoiceOverAnnouncer.reportUpdated(text)
		}

	}

	private func prepareInitialLocationIfNeeded() {
		guard !hasPreparedInitialLocation, !isLoading else { return }
		hasPreparedInitialLocation = true
		let attemptID = UUID()
		startupAttemptID = attemptID
		let operationID = beginLoadingPresentation()
		let requestPrefs = prefs
		let service = OrientSvc.interactiveSession()
		isStartupLoading = true
		isMapPreparationLoading = true
		startupTask = Task {
			defer {
				if startupAttemptID == attemptID {
					LoadingThrobber.stop()
					isStartupLoading = false
					isMapPreparationLoading = false
					startupTask = nil
					finishLoadingPresentation(operationID: operationID)
				}
			}
			VoiceOverAnnouncer.reportUpdated(startupLoadingText)
			LoadingThrobber.start(hapticsEnabled: requestPrefs.haptics)
			do {
				try await LookupAttempt.run(stage: "startup") {
					try await service.prepareInitialMapData(prefs: requestPrefs) {
						if startupAttemptID == attemptID { isStartupLoading = false }
					}
				}
				guard !Task.isCancelled, startupAttemptID == attemptID else { return }
				isMapDataReady = true
				if hasPendingLiveModeStart {
					startPendingLiveModeIfReady()
					return
				}
				ReadyEarcon.play(hapticsEnabled: requestPrefs.haptics)
				presentStatusText(readyText)
				Task { @MainActor in
					do { try await Task.sleep(for: .milliseconds(1_350)) } catch { return }
					guard startupAttemptID == attemptID else { return }
					VoiceOverAnnouncer.reportUpdated(readyText)
				}
			} catch {
				guard !Task.isCancelled, startupAttemptID == attemptID else { return }
				isMapDataReady = false
				hasPendingLiveModeStart = false
				hasPreparedInitialLocation = false
				let text = reportFailureText(.nearest, rank: 1, error: error)
				presentStatusText(text)
				VoiceOverAnnouncer.reportUpdated(text)
			}
		}
	}

	private func restartInitialPreparation() {
		cancelStartupPreparationIfNeeded()
		isMapDataReady = false
		hasPreparedInitialLocation = false
		prepareInitialLocationIfNeeded()
	}

	private func cancelStartupPreparationIfNeeded() {
		startupAttemptID = UUID()
		startupTask?.cancel()
		startupTask = nil
		LoadingThrobber.stop()
		isStartupLoading = false
		isMapPreparationLoading = false
	}

	@discardableResult
	private func startRequestedPointScanIfNeeded() -> Bool {
		guard UserDefaults.standard.bool(forKey: LaunchKeys.startPointScan) else {
			return false
		}
		UserDefaults.standard.set(false, forKey: LaunchKeys.startPointScan)
		cancelStartupPreparationIfNeeded()
		let operationID = beginLoadingPresentation()
		scanPreparationStatusOperationID = operationID
		pointScanner.setScanning(true, prefs: prefs) { text in
			handleScanModeStatus(text)
		}
		return true
	}

	private var appFooterText: String {
		let year = Calendar.current.component(.year, from: .now)
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
		let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
		return "Copyright \(year) by Marco Salsiccia\nVersion \(version) (\(build))"
	}

	private var feedbackEmailBody: String {
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
		let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
		let device = UIDevice.current
		return """


		---
		Intersector version: \(version) (\(build))
		Device: \(device.model) (\(deviceHardwareIdentifier))
		OS: \(device.systemName) \(device.systemVersion)
		"""
	}

	private var deviceHardwareIdentifier: String {
		if let simulatorIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
			return simulatorIdentifier
		}
		var systemInfo = utsname()
		uname(&systemInfo)
		return withUnsafePointer(to: &systemInfo.machine) { pointer in
			pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
				String(cString: $0)
			}
		}
	}

	private func openMailFallback() {
		var components = URLComponents()
		components.scheme = "mailto"
		components.path = "marco@marconius.com"
		components.queryItems = [
			URLQueryItem(name: "subject", value: "Intersector Feedback"),
			URLQueryItem(name: "body", value: feedbackEmailBody)
		]
		guard let mailURL = components.url else {
			return
		}
		openURL(mailURL)
	}
}

extension View {
	func accessibilityTouchRegion(
		minHeight: CGFloat,
		verticalPadding: CGFloat,
		alignment: Alignment
	) -> some View {
		self
			.padding(.vertical, verticalPadding)
			.frame(minHeight: minHeight, alignment: alignment)
			.frame(maxWidth: .infinity, alignment: alignment)
			.contentShape(Rectangle())
	}
}

extension Color {
	static let crossBg = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)
				: UIColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1)
		}
	)
	static let crossBtn = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1)
				: UIColor(red: 1.00, green: 0.82, blue: 0.20, alpha: 1)
		}
	)
	static let crossPanel = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
				: UIColor(red: 0.18, green: 0.18, blue: 0.17, alpha: 1)
		}
	)
	static let crossSettingsHeader = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
				: UIColor(red: 0.94, green: 0.94, blue: 0.91, alpha: 1)
		}
	)
	static let crossSettingsRow = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
				: UIColor(red: 1.00, green: 1.00, blue: 0.98, alpha: 1)
		}
	)
	static let crossSettingsHelper = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
				: UIColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1)
		}
	)
	static let crossSettingsDivider = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.28, green: 0.28, blue: 0.28, alpha: 1)
				: UIColor(red: 0.78, green: 0.78, blue: 0.74, alpha: 1)
		}
	)
	static let crossText = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1)
				: UIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)
		}
	)
	static let crossButtonText = Color(red: 0.02, green: 0.02, blue: 0.02)
	static let crossButtonBorder = Color(red: 0.42, green: 0.28, blue: 0.00)
	static let crossButtonStrongBorder = Color(red: 0.02, green: 0.02, blue: 0.02)
	static let crossChevron = Color(red: 0.42, green: 0.28, blue: 0.00)
	static let crossScanIdle = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 1.00, green: 0.68, blue: 0.18, alpha: 1)
				: UIColor(red: 1.00, green: 0.76, blue: 0.18, alpha: 1)
		}
	)
	static let crossScanActive = Color(red: 1.00, green: 0.55, blue: 0.12)
	static let crossInv = Color(red: 0.98, green: 0.98, blue: 0.96)
	static let crossAccent = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 1.00, green: 0.80, blue: 0.18, alpha: 1)
				: UIColor(red: 112.0 / 255, green: 85.0 / 255, blue: 0, alpha: 1)
		}
	)
	// Native switches and sliders have white thumbs in both appearances.
	static let crossControlTint = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 0.72, green: 0.46, blue: 0, alpha: 1)
				: UIColor(red: 112.0 / 255, green: 85.0 / 255, blue: 0, alpha: 1)
		}
	)
	static let crossPanelAccent = Color(
		UIColor { traits in
			traits.userInterfaceStyle == .dark
				? UIColor(red: 1.00, green: 0.80, blue: 0.18, alpha: 1)
				: UIColor(red: 0.72, green: 0.46, blue: 0.00, alpha: 1)
		}
	)
}

#if DEBUG
	#Preview {
		ContentView()
	}
#endif
