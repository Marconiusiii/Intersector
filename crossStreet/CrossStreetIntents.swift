//
//  IntersectorIntents.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import AppIntents
import Foundation

struct NearestIntersectionIntent: AppIntent {
	static var title: LocalizedStringResource = "Nearest Intersection"
	static var description = IntentDescription("Reports the closest mapped intersection.")
	static var openAppWhenRun = false

	func perform() async throws -> some IntentResult & ProvidesDialog {
		do {
			let report = try await OrientSvc.shared.report(.nearest)
			let text = await report.text(with: AppPrefs())
			return .result(dialog: IntentDialog(stringLiteral: text))
		} catch {
			return .result(
				dialog: IntentDialog(
					stringLiteral: "I couldn't get your nearest intersection. Make sure Location Services are enabled for Intersector and try again."
				)
			)
		}
	}
}

struct UpcomingIntersectionIntent: AppIntent {
	static var title: LocalizedStringResource = "Upcoming Intersection"
	static var description = IntentDescription("Reports the mapped intersection ahead.")
	static var openAppWhenRun = false

	func perform() async throws -> some IntentResult & ProvidesDialog {
		do {
			let report = try await OrientSvc.shared.report(.upcoming)
			let text = await report.text(with: AppPrefs())
			return .result(dialog: IntentDialog(stringLiteral: text))
		} catch {
			return .result(
				dialog: IntentDialog(
					stringLiteral: "I couldn't get your upcoming intersection. Make sure Location Services are enabled for Intersector and try again."
				)
			)
		}
	}
}

enum LaunchKeys {
	static let startPointScan = "startPointScanOnLaunch"
}

struct StartPointScanIntent: AppIntent {
	static var title: LocalizedStringResource = "Start Point and Scan"
	static var description = IntentDescription("Opens Intersector and starts live Point and Scan mode.")
	static var openAppWhenRun = true

	func perform() async throws -> some IntentResult & ProvidesDialog {
		UserDefaults.standard.set(true, forKey: await LaunchKeys.startPointScan)
		return .result(dialog: "Opening Intersector with Point and Scan.")
	}
}

struct IntersectorShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: NearestIntersectionIntent(),
			phrases: [
				"Nearest intersection in \(.applicationName)",
				"Where is the nearest intersection with \(.applicationName)",
				"What's my nearest intersection with \(.applicationName)",
				"What is my nearest intersection with \(.applicationName)",
				"What's the nearest intersection with \(.applicationName)",
				"What intersection am I near with \(.applicationName)"
			],
			shortTitle: "Nearest",
			systemImageName: "location.fill"
		)
		AppShortcut(
			intent: UpcomingIntersectionIntent(),
			phrases: [
				"Upcoming intersection in \(.applicationName)",
				"What intersection is ahead with \(.applicationName)",
				"What's my upcoming intersection with \(.applicationName)",
				"What is my upcoming intersection with \(.applicationName)",
				"What's the next intersection with \(.applicationName)",
				"What intersection is coming up with \(.applicationName)"
			],
			shortTitle: "Upcoming",
			systemImageName: "arrow.up.circle.fill"
		)
		AppShortcut(
			intent: StartPointScanIntent(),
			phrases: [
				"Start Point and Scan in \(.applicationName)",
				"Scan for intersections with \(.applicationName)"
			],
			shortTitle: "Point Scan",
			systemImageName: "dot.radiowaves.left.and.right"
		)
	}
}
