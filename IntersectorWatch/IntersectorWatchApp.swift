//
//  IntersectorWatchApp.swift
//  Intersector Watch App
//
//  Created by Marco Salsiccia on 6/17/26.
//

import AppIntents
import SwiftUI

@main
struct IntersectorWatchApp: App {
	init() {
		IntersectorWatchShortcuts.updateAppShortcutParameters()
	}

	var body: some Scene {
		WindowGroup {
			WatchContentView()
		}
	}
}
