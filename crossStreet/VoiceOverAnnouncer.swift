//
//  VoiceOverAnnouncer.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import Accessibility
import Foundation

enum VoiceOverAnnouncer {
	@MainActor
	static func reportUpdated(_ text: String) {
		var announcement = AttributedString(text)
		announcement.accessibilitySpeechAnnouncementPriority = .high
		AccessibilityNotification.Announcement(announcement).post()
	}
}
