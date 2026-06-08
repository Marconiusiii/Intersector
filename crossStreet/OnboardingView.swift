//
//  OnboardingView.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import SwiftUI

struct OnboardingView: View {
	var locationProvider: LocationProvider
	var onComplete: () -> Void

	@State private var page = 0
	@State private var isRequestingPermission = false
	@AccessibilityFocusState private var isTitleFocused: Bool

	private let pages = [
		OnboardingPage(
			title: "Welcome to Intersector",
			body: "Intersector helps you identify nearby intersections and orient yourself by street direction. It is built for quick, accessible street context from the app or Siri."
		),
		OnboardingPage(
			title: "Use Siri Shortcuts",
			body: "Try saying: Nearest intersection in Intersector. Upcoming intersection in Intersector. Start Point and Scan in Intersector. You can also set up your own shortcuts using Intersector in the Shortcuts app."
		),
		OnboardingPage(
			title: "Location Permission",
			body: "Intersector needs your location to find the streets and intersections around you. The next step opens the iOS location permission request."
		)
	]

	var body: some View {
		VStack(alignment: .leading, spacing: 24) {
			Spacer(minLength: 0)
			Text(pages[page].title)
				.font(.largeTitle)
				.fontWeight(.bold)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityAddTraits(.isHeader)
				.accessibilityFocused($isTitleFocused)
			Text(pages[page].body)
				.font(.title3)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
			Button {
				goNext()
			} label: {
				Text(isRequestingPermission ? "Requesting..." : "Next")
					.font(.title3)
					.fontWeight(.semibold)
					.multilineTextAlignment(.center)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 18)
			}
			.buttonStyle(.borderedProminent)
			.disabled(isRequestingPermission)
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		.background(Color.crossBg)
		.onAppear {
			focusTitle()
		}
	}

	private func goNext() {
		if page < pages.count - 1 {
			page += 1
			focusTitle()
			return
		}

		isRequestingPermission = true
		Task {
			_ = await locationProvider.requestWhenInUseAuthorization()
			isRequestingPermission = false
			onComplete()
		}
	}

	private func focusTitle() {
		isTitleFocused = false
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(100))
			isTitleFocused = true
		}
	}
}

private struct OnboardingPage {
	var title: String
	var body: String
}
