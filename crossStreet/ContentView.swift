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
	case intersectionWording
	case spokenIntersections
	case verbosity
	case haptics
}

struct ContentView: View {
	@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
	@AppStorage("areaMode") private var areaModeRaw = AreaMode.near.rawValue
	@AppStorage("detailLevel") private var detailRaw = DetailLev.standard.rawValue
	@AppStorage("measurementUnit") private var measurementUnitRaw = MeasurementUnit.feet.rawValue
	@AppStorage("directionStyle") private var directionStyleRaw = DirectionStyle.words.rawValue
	@AppStorage("intersectionWording") private var intersectionWordingRaw = IntersectionWording.direct.rawValue
	@AppStorage("spokenIntersectionCount") private var spokenIntersectionCountRaw = SpokenIntersectionCount.one.rawValue
	@AppStorage("includeCrossings") private var includeCrossings = false
	@AppStorage("includeWalkingPaths") private var includeWalkingPaths = false
	@AppStorage("hapticsEnabled") private var hapticsEnabled = true
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@Environment(\.openURL) private var openURL
	@ScaledMetric(relativeTo: .largeTitle) private var headerMinHeight: CGFloat = 88
	@ScaledMetric(relativeTo: .body) private var statusMinHeight: CGFloat = 128
	@ScaledMetric(relativeTo: .title2) private var actionMinHeight: CGFloat = 120
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
			detail: DetailLev(rawValue: detailRaw) ?? .standard,
			measurementUnit: MeasurementUnit(rawValue: measurementUnitRaw) ?? .feet,
			directionStyle: DirectionStyle(rawValue: directionStyleRaw) ?? .words,
			intersectionWording: IntersectionWording(rawValue: intersectionWordingRaw) ?? .direct,
			spokenIntersectionCount: SpokenIntersectionCount(rawValue: spokenIntersectionCountRaw) ?? .one,
			mapDetails: MapDetailOptions(
				includeCrossings: includeCrossings,
				includeWalkingPaths: includeWalkingPaths
			),
			haptics: hapticsEnabled
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
					actionButton("Nearest Intersection", systemImage: "location.fill") {
						await updateReport(.nearest)
					}
					.frame(minHeight: actionMinHeight)
					actionButton("Upcoming Intersection", systemImage: "arrow.up.circle.fill") {
						await updateReport(.upcoming)
					}
					.frame(minHeight: actionMinHeight)
					actionButton(
						"My Direction",
						systemImage: "safari.fill",
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
			actionLabel("Point and Scan", systemImage: "dot.radiowaves.left.and.right")
		}
		.toggleStyle(.button)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
		.background(Color.crossBtn)
		.contentShape(Rectangle())
		.disabled(isLoading)
	}

	private var areaModeBinding: Binding<AreaMode> {
		Binding {
			prefs.areaMode
		} set: { areaMode in
			areaModeRaw = areaMode.rawValue
			settingsFocusTarget = .neighborhood
		}
	}

	private var detailBinding: Binding<DetailLev> {
		Binding {
			prefs.detail
		} set: { detail in
			detailRaw = detail.rawValue
			settingsFocusTarget = .verbosity
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

	private var intersectionWordingBinding: Binding<IntersectionWording> {
		Binding {
			prefs.intersectionWording
		} set: { wording in
			intersectionWordingRaw = wording.rawValue
			settingsFocusTarget = .intersectionWording
		}
	}

	private var intersectionWordingDescription: String {
		switch prefs.intersectionWording {
		case .direct:
			"Names both streets at the intersection."
		case .streetContext:
			"Names the current street first, then the cross street."
		}
	}

	private var verbosityDescription: String {
		switch prefs.detail {
		case .minimal:
			"Speaks intersection names only."
		case .brief:
			"Adds distance and direction."
		case .standard:
			"Also adds available neighborhood context."
		}
	}

	private var spokenIntersectionCountBinding: Binding<SpokenIntersectionCount> {
		Binding {
			prefs.spokenIntersectionCount
		} set: { count in
			spokenIntersectionCountRaw = count.rawValue
			settingsFocusTarget = .spokenIntersections
		}
	}

	private var spokenIntersectionCountDescription: String {
		switch prefs.spokenIntersectionCount {
		case .one:
			"Speaks one nearby intersection."
		case .two:
			"Speaks the intersections on either side of your position."
		case .three:
			"Also speaks the following intersection in the direction you are facing."
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
				Text("Intersection directions and distances are estimates based on your location, device heading, and available map data. Accuracy can vary with GPS and compass conditions.")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)

				Picker("Neighborhood context", selection: areaModeBinding) {
					ForEach(AreaMode.allCases) { mode in
						Text(mode.label).tag(mode)
					}
				}
				.pickerStyle(.menu)
				.accessibilityFocused($settingsFocusTarget, equals: .neighborhood)

				Section {
					Toggle("Include crossings", isOn: crossingsBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .crossings)
					Toggle("Include walking paths", isOn: walkingPathsBinding)
						.accessibilityFocused($settingsFocusTarget, equals: .walkingPaths)
					Text("Keep Walking Paths off to focus results on the street grid.")
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
				} header: {
					Text("Map Detail")
				}

				Section {
					Picker("Intersection wording", selection: intersectionWordingBinding) {
						ForEach(IntersectionWording.allCases) { item in
							Text(item.label).tag(item)
						}
					}
					.pickerStyle(.segmented)
					.accessibilityFocused($settingsFocusTarget, equals: .intersectionWording)
					Text(intersectionWordingDescription)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
				} header: {
					Text("Intersection Wording")
				}

				Section {
					Picker("Spoken Intersections", selection: spokenIntersectionCountBinding) {
						ForEach(SpokenIntersectionCount.allCases) { count in
							Text(count.label).tag(count)
						}
					}
					.pickerStyle(.segmented)
					.accessibilityFocused($settingsFocusTarget, equals: .spokenIntersections)
					Text(spokenIntersectionCountDescription)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
				} header: {
					Text("Spoken Intersections")
				}

				Section {
					Text("Measurement Unit")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					Picker("Measurement Unit", selection: measurementUnitBinding) {
						ForEach(MeasurementUnit.allCases) { item in
							Text(item.label).tag(item)
						}
					}
					.pickerStyle(.segmented)
					.accessibilityFocused($settingsFocusTarget, equals: .measurementUnit)
				}

				Section {
					Text("Direction")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					Picker("Direction", selection: directionStyleBinding) {
						ForEach(DirectionStyle.allCases) { item in
							Text(item.label).tag(item)
						}
					}
					.pickerStyle(.segmented)
					.accessibilityFocused($settingsFocusTarget, equals: .direction)
				}

				Section {
					Text("Verbosity")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					Picker("Verbosity", selection: detailBinding) {
						ForEach(DetailLev.allCases) { item in
							Text(item.label).tag(item)
						}
					}
					.pickerStyle(.segmented)
					.accessibilityFocused($settingsFocusTarget, equals: .verbosity)
					Text(verbosityDescription)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
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
						.foregroundStyle(.secondary)
				} header: {
					Text("About Intersector")
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

	private func actionButton(
		_ title: String,
		systemImage: String,
		accessibilityHint: String? = nil,
		isDisabled: Bool? = nil,
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
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.foregroundStyle(Color.crossText)
		.background(Color.crossBtn)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.contentShape(Rectangle())
		.disabled(isDisabled ?? (isLoading || pointScanner.isScanning || pointScanner.isPreparing))
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

	private func updateReport(_ kind: ReportKind) async {
		guard !isLoading else {
			return
		}
		isLoading = true
		statusText = "Updating \(kind.intentLabel)."

		do {
			let text = try await OrientSvc.shared.spokenText(kind, prefs: prefs)
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		} catch {
			let text = "Unable to update \(kind.intentLabel). \(error.localizedDescription)"
			statusText = text
			VoiceOverAnnouncer.reportUpdated(text)
		}

		isLoading = false
	}

	private func updateDirection() async {
		guard !isDirectionLoading else {
			return
		}
		isDirectionLoading = true
		statusText = "Updating direction."

		do {
			let heading = try await directionLocationProvider.currentHeading()
			let text = "Facing \(Geo.compassDirection(heading))."
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
