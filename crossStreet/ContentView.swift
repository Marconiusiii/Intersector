//
//  ContentView.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import AVFoundation
import MessageUI
import SwiftUI
import WatchConnectivity

private enum SettingsFocusTarget: Hashable {
	case neighborhood
	case crossings
	case walkingPaths
	case measurementUnit
	case direction
	case announcementDistance
	case announcementDirection
	case announcementNeighborhood
	case intersectionDetails
	case intersectionWording
	case spokenIntersections
	case rankedControls
	case manhattanSnobMode
	case haptics
}

private let lookupLoadingText = "Intersecting..."
private let startupLoadingText = "Loading Intersector."
private let readyText = "Intersector Ready."

@MainActor
private enum IntersectorAudioSession {
	static func prepareForFeedback() {
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(
				.playback,
				mode: .default,
				options: [.duckOthers]
			)
			try session.setActive(true)
		} catch {}
	}
}

@MainActor
private enum LoadingThrobber {
	private static var player: AVAudioPlayer?
	private static var hapticTask: Task<Void, Never>?
	private static let loopDuration: TimeInterval = 2.20

	static func start(hapticsEnabled: Bool) {
		do {
			IntersectorAudioSession.prepareForFeedback()
			if player == nil {
				player = try AVAudioPlayer(data: cueData())
				player?.volume = 0.14
				player?.numberOfLoops = -1
				player?.prepareToPlay()
			}
			player?.currentTime = 0
			player?.play()
		} catch {}
		startHapticsIfNeeded(hapticsEnabled)
	}

	static func stop() {
		player?.stop()
		player?.currentTime = 0
		hapticTask?.cancel()
		hapticTask = nil
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
				frequency: 660
			) + pulseValue(
				time: time,
				start: 0.48,
				attack: 0.03,
				decay: 0.24,
				sustain: 0.07,
				frequency: 330
			) + pulseValue(
				time: time,
				start: 0.86,
				attack: 0.03,
				decay: 0.36,
				sustain: 0,
				frequency: 494
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
		for value in echoedSamples {
			let sample = Int16(max(-1, min(1, value)) * 2_300)
			data.append(sample.littleEndianData)
		}

		return data
	}

	private static func startHapticsIfNeeded(_ isEnabled: Bool) {
		hapticTask?.cancel()
		guard isEnabled else {
			hapticTask = nil
			return
		}
		hapticTask = Task { @MainActor in
			let startTime = ContinuousClock.now
			let clock = ContinuousClock()
			let pulses: [(offset: Duration, intensity: Double)] = [
				(.milliseconds(120), 0.95),
				(.milliseconds(480), 0.55),
				(.milliseconds(860), 0.25)
			]
			var loopIndex = 0
			while !Task.isCancelled {
				let loopOffset = Duration.milliseconds(Int(loopDuration * 1_000) * loopIndex)
				for pulse in pulses {
					let targetTime = startTime + loopOffset + pulse.offset
					if clock.now < targetTime {
						try? await Task.sleep(until: targetTime, clock: clock)
					}
					guard !Task.isCancelled else { return }
					HapticFeedback().pulse(intensity: pulse.intensity)
				}
				loopIndex += 1
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
		frequency: Double
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
		return sin(angle) * envelope * 0.78
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
			IntersectorAudioSession.prepareForFeedback()
			player = try AVAudioPlayer(data: cueData())
			player?.volume = 0.42
			player?.prepareToPlay()
			player?.play()
		} catch {}
		playHapticsIfNeeded(hapticsEnabled)
	}

	private static func cueData() -> Data {
		let sampleRate = 22_050
		let duration = 1.42
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
			let pulses = readyPulse(time: time, start: noteStarts[0], frequency: 494, gain: 0.58)
				+ readyPulse(time: time, start: noteStarts[1], frequency: 660, gain: 0.68)
				+ readyPulse(time: time, start: noteStarts[2], frequency: 988, gain: 0.76)
			samples.append(pad + pulses)
		}

		let echoedSamples = samples.addingEcho(
			sampleRate: sampleRate,
			taps: [
				(delay: 0.15, gain: 0.22),
				(delay: 0.34, gain: 0.10)
			]
		)
		for value in echoedSamples {
			let sample = Int16(max(-1, min(1, value)) * 2_900)
			data.append(sample.littleEndianData)
		}
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
		let sustain = 0.08
		let decay = 0.24
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
			envelope = max(0, 1 - decayProgress)
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

private extension Array where Element == Double {
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
	let intersectionWording: String
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
			intersectionWording,
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
			"intersectionWording": intersectionWording,
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
	@AppStorage("intersectionWording") private var intersectionWordingRaw = IntersectionWording.direct.rawValue
	@AppStorage("spokenIntersectionCount") private var spokenIntersectionCountRaw = SpokenIntersectionCount.one.rawValue
	@AppStorage("includeAnnouncementDistance") private var includeAnnouncementDistance = true
	@AppStorage("includeAnnouncementDirection") private var includeAnnouncementDirection = true
	@AppStorage("includeAnnouncementNeighborhood") private var includeAnnouncementNeighborhood = true
	@AppStorage("includeIntersectionDetails") private var includeIntersectionDetails = false
	@AppStorage("includeCrossings") private var includeCrossings = false
	@AppStorage("includeWalkingPaths") private var includeWalkingPaths = false
	@AppStorage("hapticsEnabled") private var hapticsEnabled = true
	@AppStorage("manhattanSnobMode") private var manhattanSnobMode = false
	@AppStorage("showRankedControls") private var showRankedControls = true
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@Environment(\.openURL) private var openURL
	@Environment(\.scenePhase) private var scenePhase
	@ScaledMetric(relativeTo: .largeTitle) private var headerMinHeight: CGFloat = 88
	@ScaledMetric(relativeTo: .body) private var statusMinHeight: CGFloat = 112
	@ScaledMetric(relativeTo: .title2) private var actionMinHeight: CGFloat = 76
	@State private var statusText = "Choose an action."
	@State private var isLoading = false
	@State private var isDirectionLoading = false
	@State private var isStartupLoading = false
	@State private var isShowingSettings = false
	@State private var isShowingMailComposer = false
	@State private var hasPreparedInitialLocation = false
	@State private var onboardingLocationProvider = LocationProvider()
	@State private var directionLocationProvider = LocationProvider()
	@StateObject private var pointScanner = PointScanController()
	@State private var watchSettingsSync = WatchSettingsSync()
	@AccessibilityFocusState private var settingsFocusTarget: SettingsFocusTarget?

	private var prefs: AppPrefs {
		AppPrefs(
			areaMode: AreaMode(rawValue: areaModeRaw) ?? .near,
			measurementUnit: MeasurementUnit(rawValue: measurementUnitRaw) ?? .feet,
			directionStyle: DirectionStyle(rawValue: directionStyleRaw) ?? .words,
			intersectionWording: IntersectionWording(rawValue: intersectionWordingRaw) ?? .direct,
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
			areaMode: areaModeRaw,
			measurementUnit: measurementUnitRaw,
			directionStyle: directionStyleRaw,
			intersectionWording: intersectionWordingRaw,
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
			ScrollView {
				VStack(spacing: 0) {
					headerView
						.frame(minHeight: headerMinHeight)
					statusView
						.frame(minHeight: statusMinHeight)
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
						isDisabled: isDirectionLoading
					) {
						await updateDirection()
					}
					.frame(minHeight: actionMinHeight)
					pointScanToggle
						.frame(minHeight: actionMinHeight)
				}
				.frame(maxWidth: .infinity)
			}
			.background(Color.crossBg)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar(.hidden, for: .navigationBar)
			.sheet(isPresented: $isShowingSettings) {
				settingsView
			}
			.onAppear {
				if !startRequestedPointScanIfNeeded() {
					prepareInitialLocationIfNeeded()
				}
				watchSettingsSync.sync(watchSettingsPayload)
			}
			.onChange(of: watchSettingsPayload.signature) { _, _ in
				watchSettingsSync.sync(watchSettingsPayload)
			}
			.onChange(of: scenePhase) { _, phase in
				if phase != .active {
					pointScanner.stopScanning()
				}
			}
		}
	}

	private var headerView: some View {
		ViewThatFits(in: .horizontal) {
			HStack {
				appTitle
				Spacer(minLength: 16)
				settingsButton
			}

			VStack(alignment: .leading, spacing: 12) {
				appTitle
				settingsButton
			}
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		.background(Color.crossBg)
		.tint(Color.crossAccent)
	}

	private var appTitle: some View {
		Text("Intersector")
			.font(.largeTitle)
			.fontWeight(.bold)
			.foregroundStyle(Color.crossText)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityAddTraits(.isHeader)
	}

	private var settingsButton: some View {
		Button("Settings") {
			isShowingSettings = true
		}
		.font(.body)
		.foregroundStyle(Color.crossText)
		.lineLimit(nil)
		.fixedSize(horizontal: false, vertical: true)
	}

	private var statusView: some View {
		Group {
			if dynamicTypeSize.isAccessibilitySize {
				VStack(alignment: .leading, spacing: 8) {
					currentInfoHeading
					currentInfoBody
				}
			} else {
				HStack(alignment: .firstTextBaseline, spacing: 16) {
					currentInfoHeading
					currentInfoBody
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		.padding(.horizontal, 16)
		.padding(.vertical, 10)
		.background(Color.crossPanel)
	}

	private var currentInfoHeading: some View {
		Text("Current Info")
			.font(.title2)
			.fontWeight(.semibold)
			.foregroundStyle(.white)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityAddTraits(.isHeader)
	}

	private var currentInfoText: some View {
		Text(statusText)
			.font(.body)
			.foregroundStyle(Color.crossInv)
			.multilineTextAlignment(.leading)
			.lineLimit(nil)
			.textSelection(.enabled)
			.fixedSize(horizontal: false, vertical: true)
	}

	private var currentInfoBody: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			if isStartupLoading {
				ProgressView()
					.tint(Color.crossAccent)
					.controlSize(.regular)
					.accessibilityHidden(true)
			}
			currentInfoText
		}
	}

	private var nearestButton: some View {
		actionButton(
			"Nearest",
			systemImage: "location.fill",
			accessibilityLabel: "Nearest Intersection",
			drawsChrome: !showRankedControls
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
			drawsChrome: !showRankedControls
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
		Toggle(
			isOn: Binding(
				get: { pointScanner.isScanning || pointScanner.isPreparing },
				set: { enabled in
					pointScanner.setScanning(enabled, prefs: prefs) { text in
						statusText = text
					}
				}
			)
		) {
			actionLabel("Scan", systemImage: "dot.radiowaves.left.and.right")
		}
		.toggleStyle(.button)
		.frame(maxWidth: .infinity, alignment: .center)
		.foregroundStyle(Color.crossButtonText)
		.background(pointScanBackground)
		.overlay(Rectangle().stroke(Color.crossButtonStrongBorder, lineWidth: 2))
		.shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
		.contentShape(Rectangle())
		.disabled(isLoading)
		.accessibilityLabel("Point and Scan")
	}

	private var pointScanBackground: Color {
		pointScanner.isScanning || pointScanner.isPreparing ? Color.crossScanActive : Color.crossBtn
	}

	private func rankedActionRow(
		primary: some View,
		menu: some View
	) -> some View {
		HStack(spacing: 0) {
			primary
			menu
				.frame(minWidth: 54)
		}
		.background(Color.crossBtn)
		.overlay(Rectangle().stroke(Color.crossButtonBorder, lineWidth: 1))
		.shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
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
				.imageScale(.large)
			.frame(maxWidth: .infinity, minHeight: actionMinHeight)
			.foregroundStyle(Color.crossChevron)
			.contentShape(Rectangle())
		}
		.menuStyle(.button)
		.buttonStyle(IntersectorActionButtonStyle(drawsChrome: false))
		.disabled(isLoading || pointScanner.isScanning || pointScanner.isPreparing)
		.accessibilityHidden(true)
	}

	private var areaModeBinding: Binding<AreaMode> {
		Binding {
			prefs.areaMode
		} set: { areaMode in
			areaModeRaw = areaMode.rawValue
			settingsFocusTarget = .neighborhood
		}
	}

	private var measurementUnitBinding: Binding<MeasurementUnit> {
		Binding {
			prefs.measurementUnit
		} set: { measurementUnit in
			measurementUnitRaw = measurementUnit.rawValue
			settingsFocusTarget = .measurementUnit
		}
	}

	private var directionStyleBinding: Binding<DirectionStyle> {
		Binding {
			prefs.directionStyle
		} set: { directionStyle in
			directionStyleRaw = directionStyle.rawValue
			settingsFocusTarget = .direction
		}
	}

	private var streetContextBinding: Binding<Bool> {
		Binding {
			prefs.intersectionWording == .streetContext
		} set: { isEnabled in
			intersectionWordingRaw = (isEnabled ? IntersectionWording.streetContext : .direct).rawValue
			settingsFocusTarget = .intersectionWording
		}
	}

	private var intersectionWordingDescription: String {
		switch prefs.intersectionWording {
		case .direct:
			"Speaks the intersection as street names."
		case .streetContext:
			"Speaks the current street first, then the cross street."
		}
	}

	private var announcementDistanceBinding: Binding<Bool> {
		Binding {
			includeAnnouncementDistance
		} set: { isEnabled in
			includeAnnouncementDistance = isEnabled
			settingsFocusTarget = .announcementDistance
		}
	}

	private var announcementDirectionBinding: Binding<Bool> {
		Binding {
			includeAnnouncementDirection
		} set: { isEnabled in
			includeAnnouncementDirection = isEnabled
			settingsFocusTarget = .announcementDirection
		}
	}

	private var announcementNeighborhoodBinding: Binding<Bool> {
		Binding {
			includeAnnouncementNeighborhood
		} set: { isEnabled in
			includeAnnouncementNeighborhood = isEnabled
			settingsFocusTarget = .announcementNeighborhood
		}
	}

	private var intersectionDetailsBinding: Binding<Bool> {
		Binding {
			includeIntersectionDetails
		} set: { isEnabled in
			includeIntersectionDetails = isEnabled
			settingsFocusTarget = .intersectionDetails
		}
	}

	private var announcementSampleText: String {
		let report = OrientReport(
			kind: .nearest,
			cross: "Crossing on Amsterdam Avenue near West 94th Street",
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
				hasPedestrianIsland: true
			)
		)
		return "Sample: \(report.text(with: prefs))"
	}

	private var spokenIntersectionSliderBinding: Binding<Double> {
		Binding {
			Double(prefs.spokenIntersectionCount.rawValue)
		} set: { value in
			let rawValue = min(3, max(1, Int(value.rounded())))
			spokenIntersectionCountRaw = rawValue
			settingsFocusTarget = .spokenIntersections
		}
	}

	private var spokenIntersectionCountDescription: String {
		switch prefs.spokenIntersectionCount {
		case .one:
			"Speaks one intersection."
		case .two:
			"Nearest speaks the two closest intersections. Upcoming speaks the first two intersections ahead."
		case .three:
			"Nearest speaks the three closest intersections. Upcoming speaks the first three intersections ahead."
		}
	}

	private var rankedControlsBinding: Binding<Bool> {
		Binding {
			showRankedControls
		} set: { isEnabled in
			showRankedControls = isEnabled
			settingsFocusTarget = .rankedControls
		}
	}

	private func spokenIntersectionAccessibilityLabel(_ count: SpokenIntersectionCount) -> String {
		switch count {
		case .one:
			"One intersection"
		case .two:
			"Two intersections"
		case .three:
			"Three intersections"
		}
	}

	private func adjustSpokenIntersections(_ direction: AccessibilityAdjustmentDirection) {
		let rawValue = prefs.spokenIntersectionCount.rawValue
		switch direction {
		case .increment:
			spokenIntersectionCountRaw = min(3, rawValue + 1)
		case .decrement:
			spokenIntersectionCountRaw = max(1, rawValue - 1)
		@unknown default:
			break
		}
		settingsFocusTarget = .spokenIntersections
	}

	private var hapticsBinding: Binding<Bool> {
		Binding {
			hapticsEnabled
		} set: { isEnabled in
			hapticsEnabled = isEnabled
			settingsFocusTarget = .haptics
		}
	}

	private var manhattanSnobModeBinding: Binding<Bool> {
		Binding {
			manhattanSnobMode
		} set: { isEnabled in
			manhattanSnobMode = isEnabled
			settingsFocusTarget = .manhattanSnobMode
		}
	}

	private var crossingsBinding: Binding<Bool> {
		Binding {
			includeCrossings
		} set: { isEnabled in
			includeCrossings = isEnabled
			settingsFocusTarget = .crossings
		}
	}

	private var walkingPathsBinding: Binding<Bool> {
		Binding {
			includeWalkingPaths
		} set: { isEnabled in
			includeWalkingPaths = isEnabled
			settingsFocusTarget = .walkingPaths
		}
	}

	private var settingsView: some View {
		NavigationStack {
			Form {
				settingsHelperText("Intersection directions and distances are estimates based on your location, device heading, and available map data. Accuracy can vary with GPS and compass conditions.")

				Section {
					Toggle("Distance", isOn: announcementDistanceBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .announcementDistance)
					if includeAnnouncementDistance {
						Picker("Measurement Unit", selection: measurementUnitBinding) {
							ForEach(MeasurementUnit.allCases) { item in
								Text(item.label).tag(item)
							}
						}
						.pickerStyle(.segmented)
						.accessibilityFocused($settingsFocusTarget, equals: .measurementUnit)
					}
					Toggle("Direction", isOn: announcementDirectionBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .announcementDirection)
					if includeAnnouncementDirection {
						Picker("Direction Style", selection: directionStyleBinding) {
							ForEach(DirectionStyle.allCases) { item in
								Text(item.label).tag(item)
							}
						}
						.pickerStyle(.segmented)
						.accessibilityFocused($settingsFocusTarget, equals: .direction)
					}
					Toggle("Manhattan Snob Mode", isOn: manhattanSnobModeBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .manhattanSnobMode)
					settingsHelperText("Uses Uptown, Downtown, East Side, and West Side when direction wording supports it.")
					Toggle("Neighborhood", isOn: announcementNeighborhoodBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .announcementNeighborhood)
					if includeAnnouncementNeighborhood {
						Picker("Neighborhood Context", selection: areaModeBinding) {
							ForEach(AreaMode.allCases) { mode in
								Text(mode.label).tag(mode)
							}
						}
						.pickerStyle(.menu)
						.accessibilityFocused($settingsFocusTarget, equals: .neighborhood)
					}
					Toggle("Street Context", isOn: streetContextBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .intersectionWording)
					settingsHelperText(intersectionWordingDescription)
					Toggle("Intersection Details", isOn: intersectionDetailsBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .intersectionDetails)
					VStack(alignment: .leading, spacing: 8) {
						Text("Spoken Intersections")
							.foregroundStyle(Color.crossText)
						Slider(
							value: spokenIntersectionSliderBinding,
							in: 1...3,
							step: 1
						)
					}
					.accessibilityElement(children: .ignore)
					.accessibilityFocused($settingsFocusTarget, equals: .spokenIntersections)
					.accessibilityLabel("Spoken Intersections")
					.accessibilityValue(spokenIntersectionAccessibilityLabel(prefs.spokenIntersectionCount))
					.accessibilityAdjustableAction(adjustSpokenIntersections)
					settingsHelperText(spokenIntersectionCountDescription)
					Toggle("Show 2nd and 3rd Controls", isOn: rankedControlsBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .rankedControls)
						.accessibilityHint("Toggles the visibility of the menu chevrons")
					Text("Sample Announcement")
						.font(.headline)
						.foregroundStyle(Color.crossText)
						.accessibilityAddTraits(.isHeader)
					settingsHelperText(announcementSampleText)
				} header: {
					settingsHeader("Announcements")
				}

				Section {
					Toggle("Include crossings", isOn: crossingsBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .crossings)
					Toggle("Include walking paths", isOn: walkingPathsBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .walkingPaths)
					settingsHelperText("Keep Walking Paths off to focus results on the street grid.")
				} header: {
					settingsHeader("Map Detail")
				}

				Toggle("Haptic scan feedback", isOn: hapticsBinding)
					.accessibilityFocused($settingsFocusTarget, equals: .haptics)

				Section {
					Button {
						if MFMailComposeViewController.canSendMail() {
							isShowingMailComposer = true
						} else {
							openMailFallback()
						}
					} label: {
						Text("Send Intersector Feedback")
							.lineLimit(nil)
							.fixedSize(horizontal: false, vertical: true)
					}
					.accessibilityHint("Opens Mail so you can send feedback about Intersector.")

					externalLink(title: "Privacy Policy", url: "https://marconius.com/csPrivacy/")

					DisclosureGroup("Acknowledgements") {
						VStack(alignment: .leading, spacing: 8) {
							Text("Special thanks to Jen Walz for inspiring the creation of this app!")
								.lineLimit(nil)
								.fixedSize(horizontal: false, vertical: true)
							Text("Map data from OpenStreetMap, available under the Open Database License.")
								.lineLimit(nil)
								.fixedSize(horizontal: false, vertical: true)
							Link(
								"OpenStreetMap copyright and licence",
								destination: URL(string: "https://www.openstreetmap.org/copyright")!
							)
						}
						.font(.footnote)
					}

					Text(appFooterText)
						.font(.footnote)
						.multilineTextAlignment(.center)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: .infinity, alignment: .center)
						.foregroundStyle(Color.crossText)
				} header: {
					settingsHeader("About Intersector")
				}
			}
			.scrollContentBackground(.hidden)
			.background(Color.crossBg)
			.tint(Color.crossAccent)
			.navigationTitle("Settings")
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
					body: nil,
					onFinish: { _ in }
				)
			}
		}
	}

	private func settingsHeader(_ title: String) -> some View {
		Text(title)
			.font(.headline)
			.foregroundStyle(Color.crossText)
			.textCase(nil)
	}

	private func settingsHelperText(_ text: String) -> some View {
		Text(text)
			.font(.footnote)
			.foregroundStyle(Color.crossText)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
	}

	private func actionButton(
		_ title: String,
		systemImage: String,
		accessibilityLabel: String? = nil,
		accessibilityHint: String? = nil,
		isDisabled: Bool? = nil,
		drawsChrome: Bool = true,
		action: @escaping () async -> Void
	) -> some View {
		Button {
			Task {
				await action()
			}
		} label: {
			ZStack {
				Color.clear
				actionLabel(title, systemImage: systemImage)
			}
			.frame(maxWidth: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(IntersectorActionButtonStyle(drawsChrome: drawsChrome))
		.frame(maxWidth: .infinity)
		.contentShape(Rectangle())
		.disabled(isDisabled ?? (isLoading || pointScanner.isScanning || pointScanner.isPreparing))
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

	private func updateReport(_ kind: ReportKind, rank: Int = 1) async {
		guard !isLoading else {
			return
		}
		isLoading = true
		let loadingTask = Task { @MainActor in
			do {
				try await Task.sleep(for: .milliseconds(800))
				statusText = lookupLoadingText
				LoadingThrobber.start(hapticsEnabled: prefs.haptics)
			} catch {}
		}

		do {
			let text = if rank == 1 {
				try await OrientSvc.shared.spokenText(kind, prefs: prefs)
			} else {
				try await OrientSvc.shared.report(kind, rank: rank, prefs: prefs).text(with: prefs, rank: rank)
			}
			loadingTask.cancel()
			LoadingThrobber.stop()
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		} catch {
			loadingTask.cancel()
			LoadingThrobber.stop()
			let text = "Unable to update \(reportLabel(kind, rank: rank)). \(error.localizedDescription)"
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		}

		isLoading = false
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
		isDirectionLoading = true
		let loadingText = "Checking direction."
		statusText = loadingText
		VoiceOverAnnouncer.reportUpdated(loadingText)

		do {
			let heading = try await directionLocationProvider.currentHeading(allowCached: false)
			let text = "Facing \(Geo.localizedDirection(heading, prefs: prefs))."
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		} catch {
			let text = error.localizedDescription
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		}

		isDirectionLoading = false
	}

	private func prepareInitialLocationIfNeeded() {
		guard !hasPreparedInitialLocation else {
			return
		}
		hasPreparedInitialLocation = true
		Task {
			isStartupLoading = true
			statusText = startupLoadingText
			VoiceOverAnnouncer.reportUpdated(startupLoadingText)
			LoadingThrobber.start(hapticsEnabled: prefs.haptics)

			guard await OrientSvc.shared.prewarmLocation() else {
				LoadingThrobber.stop()
				isStartupLoading = false
				statusText = "Choose an action."
				return
			}
			let isReady = await OrientSvc.shared.prewarmInitialNearestMapData(prefs: prefs)
			guard isReady, statusText != readyText else {
				LoadingThrobber.stop()
				isStartupLoading = false
				return
			}
			LoadingThrobber.stop()
			isStartupLoading = false
			ReadyEarcon.play(hapticsEnabled: prefs.haptics)
			statusText = readyText
			Task { @MainActor in
				try? await Task.sleep(for: .milliseconds(1_350))
				VoiceOverAnnouncer.reportUpdated(readyText)
			}
		}
	}

	@discardableResult
	private func startRequestedPointScanIfNeeded() -> Bool {
		guard UserDefaults.standard.bool(forKey: LaunchKeys.startPointScan) else {
			return false
		}
		UserDefaults.standard.set(false, forKey: LaunchKeys.startPointScan)
		pointScanner.setScanning(true, prefs: prefs) { text in
			statusText = text
		}
		return true
	}

	private var appFooterText: String {
		let year = Calendar.current.component(.year, from: .now)
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
		let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
		return "Copyright \(year) by Marco Salsiccia\nVersion \(version) (\(build))"
	}

	private func openMailFallback() {
		let subject = "Intersector Feedback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
		guard let mailURL = URL(string: "mailto:marco@marconius.com?subject=\(subject)") else {
			return
		}
		openURL(mailURL)
	}
}

private struct IntersectorActionButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled
	var drawsChrome = true

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.foregroundStyle(Color.crossButtonText)
			.background(drawsChrome ? Color.crossBtn : Color.clear)
			.overlay(Rectangle().stroke(drawsChrome ? Color.crossButtonBorder : Color.clear, lineWidth: 1))
			.shadow(
				color: drawsChrome ? Color.black.opacity(configuration.isPressed ? 0.06 : 0.12) : Color.clear,
				radius: 2,
				x: 0,
				y: 1
			)
			.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
			.scaleEffect(configuration.isPressed ? 0.985 : 1)
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
	static let crossScanActive = Color(red: 1.00, green: 0.55, blue: 0.12)
	static let crossInv = Color(red: 0.98, green: 0.98, blue: 0.96)
	static let crossAccent = Color(
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
