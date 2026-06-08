//
//  ContentView.swift
//  crossStreet
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
	@State private var isShowingSettings = false
	@State private var isShowingMailComposer = false
	@State private var hasLoadedInitialReport = false
	@State private var onboardingLocationProvider = LocationProvider()
	@StateObject private var pointScanner = PointScanController()

	var body: some View {
		if hasCompletedOnboarding {
			mainView
		} else {
			OnboardingView(locationProvider: onboardingLocationProvider) {
				hasCompletedOnboarding = true
			}
		}
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
							pointScanToggle
								.frame(minHeight: 150)
						}
						.frame(maxWidth: .infinity)
					}
					.frame(width: proxy.size.width, height: proxy.size.height)
					.background(Color.crossBg)
				} else {
					let headerHeight = 72.0
					let sectionHeight = max((proxy.size.height - headerHeight) / 4, 0)
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
	}

	private var appTitle: some View {
		Text("CrossStreet")
			.font(.largeTitle)
			.fontWeight(.bold)
			.lineLimit(nil)
			.fixedSize(horizontal: false, vertical: true)
			.accessibilityAddTraits(.isHeader)
	}

	private var settingsButton: some View {
		Button("Settings") {
			isShowingSettings = true
		}
		.font(.body)
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
					.accessibilityHint("Opens Mail so you can send feedback about CrossStreet.")
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
					subject: "CrossStreet Feedback",
					body: nil,
					onFinish: { _ in }
				)
			}
		}
	}

	private func actionButton(
		_ title: String,
		systemImage: String,
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
		.disabled(isLoading || pointScanner.isScanning || pointScanner.isPreparing)
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
		let subject = "CrossStreet Feedback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
		guard let mailURL = URL(string: "mailto:marco@marconius.com?subject=\(subject)") else {
			return
		}
		openURL(mailURL)
	}
}

extension Color {
	static let crossBg = Color(red: 0.96, green: 0.98, blue: 0.97)
	static let crossBtn = Color(red: 0.88, green: 0.95, blue: 0.93)
	static let crossPanel = Color(red: 0.10, green: 0.16, blue: 0.17)
	static let crossText = Color(red: 0.02, green: 0.04, blue: 0.04)
	static let crossInv = Color(red: 0.94, green: 1.00, blue: 0.98)
}

#Preview {
	ContentView()
}
