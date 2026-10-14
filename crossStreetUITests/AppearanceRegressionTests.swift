import XCTest
import UIKit

final class AppearanceRegressionTests: XCTestCase {
    @MainActor
    private func launch(_ size: UIContentSizeCategory) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasCompletedOnboarding", "YES",
            "-hapticsEnabled", "NO",
            "-UIPreferredContentSizeCategoryName", size.rawValue
        ]
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHeaderAndSettingsAtLargestTextSize() throws {
        continueAfterFailure = false
        var app = launch(.large)
        let title = app.staticTexts["Intersector"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let standardHeight = title.frame.height
        capture(app, "Home-standard")
        app.buttons["Settings"].tap()
        let settings = app.staticTexts["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let settingsHeight = settings.frame.height
        capture(app, "Settings-standard")
        app.terminate()

        app = launch(.accessibilityExtraExtraExtraLarge)
        let largeTitle = app.staticTexts["Intersector"].firstMatch
        XCTAssertTrue(largeTitle.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(largeTitle.frame.height, standardHeight * 1.3)
        XCTAssertLessThanOrEqual(largeTitle.frame.maxX, app.frame.maxX)
        XCTAssertTrue(app.buttons["Settings"].isHittable)
        capture(app, "Home-accessibility-largest")
        app.buttons["Settings"].tap()
        let largeSettings = app.staticTexts["Settings"].firstMatch
        XCTAssertTrue(largeSettings.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(largeSettings.frame.height, settingsHeight * 1.3)
        XCTAssertLessThanOrEqual(largeSettings.frame.maxX, app.frame.maxX)
        capture(app, "Settings-accessibility-largest")
        for index in 1...5 {
            app.scrollViews.firstMatch.swipeUp()
            capture(app, "Settings-accessibility-scroll-\(index)")
        }
    }
}
