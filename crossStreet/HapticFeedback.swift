//
//  HapticFeedback.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import UIKit

@MainActor
struct HapticFeedback {
	func pulse(intensity: Double) {
		let style: UIImpactFeedbackGenerator.FeedbackStyle
		switch intensity {
		case 0.75...:
			style = .heavy
		case 0.4..<0.75:
			style = .medium
		default:
			style = .light
		}

		let generator = UIImpactFeedbackGenerator(style: style)
		generator.prepare()
		generator.impactOccurred(intensity: max(0.15, min(intensity, 1.0)))
	}

	func identify() {
		UINotificationFeedbackGenerator().notificationOccurred(.success)
	}
}
