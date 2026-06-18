//
//  WatchContentView.swift
//  Intersector Watch App
//
//  Created by Marco Salsiccia on 6/17/26.
//

import SwiftUI

struct WatchContentView: View {
	@State private var statusText = "Choose an action."
	@State private var isLoading = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				Text("Intersector")
					.font(.headline)
					.accessibilityAddTraits(.isHeader)
				Text(statusText)
					.font(.body)
					.lineLimit(nil)
					.fixedSize(horizontal: false, vertical: true)
				Button {
					Task {
						await update(.nearest)
					}
				} label: {
					Label("Nearest", systemImage: "location.fill")
				}
				.disabled(isLoading)
				Button {
					Task {
						await update(.upcoming)
					}
				} label: {
					Label("Upcoming", systemImage: "arrow.up.circle.fill")
				}
				.disabled(isLoading)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func update(_ kind: WatchReportKind) async {
		guard !isLoading else {
			return
		}
		isLoading = true
		statusText = "Updating \(kind.intentLabel)."
		statusText = await IntersectorWatchReporter.reportText(for: kind)
		isLoading = false
	}
}
