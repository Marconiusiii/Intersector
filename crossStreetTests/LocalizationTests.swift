import Foundation
import AVFoundation
import Testing
@testable import Intersector

@MainActor
struct LocalizationTests {
    @Test(arguments: ["en", "es", "pt-BR", "fr", "de", "it"])
    func reportsUseBundledLanguage(language: String) {
        L10n.$languageOverride.withValue(language) {
            let expected = ["en": "Nearest: Foothill Blvd and Stanley Ave, about 35 meters ahead, signalized intersection, pedestrian island.",
                            "es": "Más cercana: Foothill Blvd y Stanley Ave, a unos 35 metros adelante, intersección con semáforo, isleta de refugio peatonal.",
                            "pt-BR": "Mais próximo: Foothill Blvd e Stanley Ave, a cerca de 35 metros à frente, cruzamento com semáforo, ilha de refúgio para pedestres.",
                            "fr": "Plus proche: Foothill Blvd et Stanley Ave, à environ 35 mètres devant, intersection avec feux, îlot piéton.",
                            "de": "Nächste: Foothill Blvd und Stanley Ave, etwa 35 Meter voraus, Kreuzung mit Ampel, Fußgängerinsel.",
                            "it": "Più vicino: Foothill Blvd e Stanley Ave, a circa 35 metri davanti, incrocio con semaforo, isola pedonale salvagente."]
            var prefs = AppPrefs(measurementUnit: .meters)
            prefs.announcementOptions.includeNeighborhood = false
            prefs.announcementOptions.includeIntersectionDetails = true
            let report = OrientReport(kind: .nearest,
                cross: L10n.text("%@ and %@", "Foothill Blvd", "Stanley Ave"),
                dist: Geo.spokenDistance(35, unit: .meters), relDir: L10n.text("ahead"),
                relDegrees: 0, street: "Foothill Blvd", crossStreet: "Stanley Ave", head: Geo.compassDirection(0),
                conf: .high, intersectionDetails: IntersectionDetails(isSignalized: true, hasPedestrianIsland: true, isStreetIntersection: true))
            #expect(report.text(with: prefs) == expected[language])
            #expect(!report.text(with: prefs, includeLead: false).contains(L10n.text("Nearest")))
            let ranked = report.text(with: prefs, rank: 2)
            #expect(ranked.hasPrefix(["en": "2nd Nearest:", "es": "Segunda más cercana:", "pt-BR": "Segundo mais próximo:", "fr": "Deuxième plus proche:", "de": "Zweite nächstgelegene:", "it": "Secondo più vicino:"][language]!))
            #expect(Geo.localizedDirection(0, prefs: AppPrefs(manhattanSnobMode: true)) == "Uptown")
            #expect(Geo.compassDirection(90) == ["en": "east", "es": "este", "pt-BR": "leste", "fr": "est", "de": "Osten", "it": "est"][language])
        }
    }

    @Test(arguments: ["en", "es", "pt-BR", "fr", "de", "it"])
    func pluralsAndDecimalSeparators(language: String) {
        L10n.$languageOverride.withValue(language) {
            #expect(L10n.quantity("%lld minutes", 1) == ["en": "1 minute", "es": "1 minuto", "pt-BR": "1 minuto", "fr": "1 minute", "de": "1 Minute", "it": "1 minuto"][language])
            #expect(L10n.quantity("%lld minutes", 2) == ["en": "2 minutes", "es": "2 minutos", "pt-BR": "2 minutos", "fr": "2 minutes", "de": "2 Minuten", "it": "2 minuti"][language])
            #expect(Geo.spokenDistance(1500, unit: .meters) == ["en": "1.5 kilometers", "es": "1,5 kilómetros", "pt-BR": "1,5 quilômetro", "fr": "1,5 kilomètre", "de": "1,5 Kilometer", "it": "1,5 chilometri"][language])
        }
    }

    @Test(arguments: ["en", "es", "pt-BR", "fr", "de", "it"])
    func unitChoiceSurvivesLanguageChanges(language: String) throws {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        L10n.$languageOverride.withValue(language) { L10n.initializeUnits(in: defaults) }
        let expected = language == "en" ? "feet" : "meters"
        #expect(defaults.string(forKey: "measurementUnit") == expected)
        L10n.$languageOverride.withValue("en") { L10n.initializeUnits(in: defaults) }
        #expect(defaults.string(forKey: "measurementUnit") == expected)
        defaults.removeObject(forKey: "measurementUnit")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        L10n.$languageOverride.withValue(language) { L10n.initializeUnits(in: defaults) }
        #expect(defaults.string(forKey: "measurementUnit") == "feet")
    }

    @Test(arguments: ["pt-BR", "fr", "de", "it"])
    func automaticVoiceMatchesContent(language: String) {
        L10n.$languageOverride.withValue(language) {
            if let voice = SystemSpeechController.voice(for: "") {
                #expect(Locale(identifier: voice.language).language.languageCode == L10n.locale.language.languageCode)
                if language == "pt-BR" { #expect(voice.language == "pt-BR") }
            }
        }
    }
}
