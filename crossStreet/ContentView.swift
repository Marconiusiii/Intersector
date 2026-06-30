//
//  ContentView.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import MessageUI
import SwiftUI

private enum SettingsFocusTarget: Hashable {
	case neighborhood
	case crossings
	case walkingPaths
	case measurementUnit
	case direction
	case announcementDistance
	case announcementDirection
	case announcementNeighborhood
	case intersectionWording
	case spokenIntersections
	case rankedControls
	case manhattanSnobMode
	case haptics
}

private let lookupLoadingText = "Intersecting..."

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
	@State private var isShowingSettings = false
	@State private var isShowingMailComposer = false
	@State private var hasLoadedInitialReport = false
	@State private var onboardingLocationProvider = LocationProvider()
	@State private var directionLocationProvider = LocationProvider()
	@StateObject private var pointScanner = PointScanController()
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
				includeNeighborhood: includeAnnouncementNeighborhood
			),
			mapDetails: MapDetailOptions(
				includeCrossings: includeCrossings,
				includeWalkingPaths: includeWalkingPaths
			),
			haptics: hapticsEnabled,
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
				loadInitialReportIfNeeded()
				startRequestedPointScanIfNeeded()
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
					currentInfoText
				}
			} else {
				HStack(alignment: .firstTextBaseline, spacing: 16) {
					currentInfoHeading
					currentInfoText
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

	private var announcementSampleText: String {
		let report = OrientReport(
			kind: .nearest,
			cross: "Amsterdam Avenue and West 94th Street",
			dist: "120 feet",
			relDir: "ahead",
			relDegrees: 0,
			street: "Amsterdam Avenue",
			crossStreet: "West 94th Street",
			head: "north",
			area: "Upper West Side",
			toward: "Manhattan Valley",
			conf: .high
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
						if prefs.directionStyle == .words {
							Toggle("Manhattan Snob Mode", isOn: manhattanSnobModeBinding)
								.accessibilityFocused($settingsFocusTarget, equals: .manhattanSnobMode)
							settingsHelperText("Uses Uptown, Downtown, East Side, and West Side for cardinal direction wording.")
						}
					}
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
					Text("Spoken Intersections")
						.foregroundStyle(Color.crossText)
					Slider(
						value: spokenIntersectionSliderBinding,
						in: 1...3,
						step: 1
					) {
						Text("Spoken Intersections")
					} minimumValueLabel: {
						Text("1")
					} maximumValueLabel: {
						Text("3")
					}
					.accessibilityFocused($settingsFocusTarget, equals: .spokenIntersections)
					.accessibilityLabel("Spoken Intersections")
					.accessibilityValue(spokenIntersectionAccessibilityLabel(prefs.spokenIntersectionCount))
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
		statusText = lookupLoadingText
		VoiceOverAnnouncer.reportUpdated(lookupLoadingText)

		do {
			let text = if rank == 1 {
				try await OrientSvc.shared.spokenText(kind, prefs: prefs)
			} else {
				try await OrientSvc.shared.report(kind, rank: rank, prefs: prefs).text(with: prefs, rank: rank)
			}
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		} catch {
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

	private func loadInitialReportIfNeeded() {
		guard !hasLoadedInitialReport else {
			return
		}
		hasLoadedInitialReport = true
		Task {
			await updateReport(.nearest)
		}
	}

	private func startRequestedPointScanIfNeeded() {
		guard UserDefaults.standard.bool(forKey: LaunchKeys.startPointScan) else {
			return
		}
		UserDefaults.standard.set(false, forKey: LaunchKeys.startPointScan)
		pointScanner.setScanning(true, prefs: prefs) { text in
			statusText = text
		}
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
