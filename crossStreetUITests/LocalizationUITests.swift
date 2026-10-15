import XCTest
import UIKit

final class LocalizationUITests: XCTestCase {
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSpanish() { checkLanguage("es", settings: "Configuración", help: "Ayuda", next: "Siguiente") }

    @MainActor
    func testBrazilianPortuguese() { checkLanguage("pt-BR", settings: "Configurações", help: "Ajuda", next: "Avançar") }

    @MainActor
    func testFrench() { checkLanguage("fr", settings: "Réglages", help: "Aide", next: "Suivant") }

    @MainActor
    func testGerman() { checkLanguage("de", settings: "Einstellungen", help: "Hilfe", next: "Weiter") }

    @MainActor
    func testItalian() { checkLanguage("it", settings: "Impostazioni", help: "Aiuto", next: "Avanti") }

    @MainActor
    private func checkLanguage(_ language: String, settings: String, help: String, next: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        let languageArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", ["es": "es_ES", "pt-BR": "pt_BR", "fr": "fr_FR", "de": "de_DE", "it": "it_IT"][language]!, "-hapticsEnabled", "NO"]
        app.launchArguments = languageArguments + ["-hasCompletedOnboarding", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons[next].waitForExistence(timeout: 10))
        capture(app, "\(language)-onboarding")
        app.terminate()

        for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            app.launchArguments = languageArguments + ["-hasCompletedOnboarding", "YES", "-UIPreferredContentSizeCategoryName", size.rawValue]
            app.launch()
            let settingsButton = app.buttons[settings].firstMatch
            XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
            XCTAssertTrue(settingsButton.isHittable)
            XCTAssertLessThanOrEqual(settingsButton.frame.maxX, app.frame.maxX + 1)
            XCTAssertTrue(app.buttons[["es": "Explorar", "pt-BR": "Explorar", "fr": "Balayer", "de": "Scannen", "it": "Esplora"][language]!].exists)
            capture(app, "\(language)-home-\(size.rawValue)")
            settingsButton.tap()
            XCTAssertTrue(app.buttons[help].waitForExistence(timeout: 5))
            capture(app, "\(language)-settings-\(size.rawValue)")
            app.buttons[help].tap()
            let welcome = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", ["es": "Intersector te ayuda", "pt-BR": "O Intersector ajuda", "fr": "Intersector vous aide", "de": "Intersector hilft Ihnen", "it": "Intersector ti aiuta"][language]!)).firstMatch
            XCTAssertTrue(welcome.waitForExistence(timeout: 5))
            capture(app, "\(language)-help-\(size.rawValue)")
            app.terminate()
        }
    }
}
