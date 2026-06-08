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
		let report = try await OrientSvc.shared.report(.nearest)
		return .result(dialog: IntentDialog(stringLiteral: report.text(with: AppPrefs())))
	}
}

struct UpcomingIntersectionIntent: AppIntent {
	static var title: LocalizedStringResource = "Upcoming Intersection"
	static var description = IntentDescription("Reports the mapped intersection ahead.")
	static var openAppWhenRun = false

	func perform() async throws -> some IntentResult & ProvidesDialog {
		let report = try await OrientSvc.shared.report(.upcoming)
		return .result(dialog: IntentDialog(stringLiteral: report.text(with: AppPrefs())))
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
		UserDefaults.standard.set(true, forKey: LaunchKeys.startPointScan)
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
				"What's my nearest intersection with \(.applicationName)"
			],
			shortTitle: "Nearest",
			systemImageName: "location.fill"
		)
		AppShortcut(
			intent: UpcomingIntersectionIntent(),
			phrases: [
				"Upcoming intersection in \(.applicationName)",
				"What intersection is ahead with \(.applicationName)",
				"What's my opcoming intersection with \(.applicationName)"
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
