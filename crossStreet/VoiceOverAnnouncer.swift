//
//  VoiceOverAnnouncer.swift
//  crossStreet
//
//  Created by Marco Salsiccia on 6/7/26.
//

import UIKit

enum VoiceOverAnnouncer {
	@MainActor
	static func reportUpdated(_ text: String) {
		guard UIAccessibility.isVoiceOverRunning else {
			return
		}
		UIAccessibility.post(notification: .announcement, argument: text)
	}
}
