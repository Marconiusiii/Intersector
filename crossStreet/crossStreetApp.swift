//
//  IntersectorApp.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import SwiftUI
import AppIntents

@main
struct IntersectorApp: App {
	init() {
		IntersectorShortcuts.updateAppShortcutParameters()
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
		}
	}
}
