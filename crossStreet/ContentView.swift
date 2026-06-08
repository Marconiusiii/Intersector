//
//  ContentView.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import MessageUI
import SwiftUI

struct ContentView: View {
	@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	@Environment(\.openURL) private var openURL
	@State private var prefs = AppPrefs()
	@State private var report: OrientReport?
	@State private var statusText = "Choose an action."
	@State private var isLoading = false
	@State private var isDirectionLoading = false
	@State private var isShowingSettings = false
	@State private var isShowingMailComposer = false
	@State private var hasLoadedInitialReport = false
	@State private var onboardingLocationProvider = LocationProvider()
	@State private var directionLocationProvider = LocationProvider()
	@StateObject private var pointScanner = PointScanController()

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
			GeometryReader { proxy in
				if dynamicTypeSize.isAccessibilitySize {
					ScrollView {
						VStack(spacing: 0) {
							headerView
								.frame(minHeight: 112)
							statusView
								.frame(minHeight: 180)
							actionButton("Nearest Intersection", systemImage: "location.fill") {
								await updateReport(.nearest)
							}
							.frame(minHeight: 150)
							actionButton("Upcoming Intersection", systemImage: "arrow.up.circle.fill") {
								await updateReport(.upcoming)
							}
							.frame(minHeight: 150)
							actionButton(
								"My Direction",
								systemImage: "safari.fill",
								accessibilityHint: "Speaks cardinal direction.",
								isDisabled: isDirectionLoading
							) {
								await updateDirection()
							}
							.frame(minHeight: 150)
							pointScanToggle
								.frame(minHeight: 150)
						}
						.frame(maxWidth: .infinity)
					}
					.frame(width: proxy.size.width, height: proxy.size.height)
					.background(Color.crossBg)
				} else {
					let headerHeight = 72.0
					let sectionHeight = max((proxy.size.height - headerHeight) / 5, 0)
					VStack(spacing: 0) {
						headerView
							.frame(height: headerHeight)
						statusView
							.frame(height: sectionHeight)
						actionButton("Nearest Intersection", systemImage: "location.fill") {
							await updateReport(.nearest)
						}
						.frame(height: sectionHeight)
						actionButton("Upcoming Intersection", systemImage: "arrow.up.circle.fill") {
							await updateReport(.upcoming)
						}
						.frame(height: sectionHeight)
						actionButton(
							"My Direction",
							systemImage: "safari.fill",
							accessibilityHint: "Speaks cardinal direction.",
							isDisabled: isDirectionLoading
						) {
							await updateDirection()
						}
						.frame(height: sectionHeight)
						pointScanToggle
							.frame(height: sectionHeight)
					}
					.frame(width: proxy.size.width, height: proxy.size.height)
					.background(Color.crossBg)
				}
			}
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

	private var settingsView: some View {
		NavigationStack {
			Form {
				Picker("Neighborhood context", selection: $prefs.areaMode) {
					ForEach(AreaMode.allCases) { mode in
						Text(mode.label).tag(mode)
					}
				}
				.pickerStyle(.menu)

				Section {
					Text("Verbosity")
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					Picker("Verbosity", selection: $prefs.detail) {
						ForEach(DetailLev.allCases) { item in
							Text(item.label).tag(item)
						}
					}
					.pickerStyle(.segmented)
				}

				Toggle("Haptic scan feedback", isOn: $prefs.haptics)

				Section {
					Button {
						if MFMailComposeViewController.canSendMail() {
							isShowingMailComposer = true
						} else {
							openMailFallback()
						}
					} label: {
						Text("Send Feedback")
							.lineLimit(nil)
							.fixedSize(horizontal: false, vertical: true)
					}
					.accessibilityHint("Opens Mail so you can send feedback about Intersector.")
				}
				Section {
					externalLink(title: "Privacy Policy", url: "https://marconius.com/csPrivacy/")
				}

				Section {
					DisclosureGroup("Acknowledgements") {
						VStack(alignment: .leading, spacing: 8) {
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
				}

				Section {
					Text(appFooterText)
						.font(.footnote)
						.multilineTextAlignment(.center)
						.lineLimit(nil)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: .infinity, alignment: .center)
						.foregroundStyle(.secondary)
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
			let updatedReport = try await OrientSvc.shared.report(kind, prefs: prefs)
			report = updatedReport
			let text = updatedReport.text(with: prefs)
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

#Preview {
	ContentView()
}
