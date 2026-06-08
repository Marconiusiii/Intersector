//
//  MailComposerView.swift
//  Intersector
//
//  Created by Marco Salsiccia on 6/7/26.
//

import MessageUI
import SwiftUI

struct MailComposerView: UIViewControllerRepresentable {
	let recipient: String
	let subject: String
	let body: String?
	let onFinish: (MFMailComposeResult) -> Void

	@Environment(\.dismiss) private var dismiss

	func makeCoordinator() -> Coordinator {
		Coordinator(dismiss: dismiss, onFinish: onFinish)
	}

	func makeUIViewController(context: Context) -> MFMailComposeViewController {
		let controller = MFMailComposeViewController()
		controller.mailComposeDelegate = context.coordinator
		controller.setToRecipients([recipient])
		controller.setSubject(subject)

		if let body {
			controller.setMessageBody(body, isHTML: false)
		}

		return controller
	}

	func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
	}

	final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
		let dismiss: DismissAction
		let onFinish: (MFMailComposeResult) -> Void

		init(dismiss: DismissAction, onFinish: @escaping (MFMailComposeResult) -> Void) {
			self.dismiss = dismiss
			self.onFinish = onFinish
		}

		func mailComposeController(
			_ controller: MFMailComposeViewController,
			didFinishWith result: MFMailComposeResult,
			error: Error?
		) {
			onFinish(result)
			dismiss()
		}
	}
}
