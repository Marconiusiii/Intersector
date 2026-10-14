import Foundation

/// The same catalog and formatter are compiled into the iPhone and Watch apps.
enum L10n {
    // Scoped overrides let formatter tests exercise actual bundled resources without
    // changing global device preferences or affecting concurrent work.
    @TaskLocal nonisolated static var languageOverride: String?

    nonisolated static var bundle: Bundle {
        guard let languageOverride,
              let path = Bundle.main.path(forResource: languageOverride, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }
    nonisolated static var language: String {
        languageOverride.flatMap { Bundle.main.localizations.contains($0) ? $0 : nil }
            ?? Bundle.main.preferredLocalizations.first ?? "en"
    }

    nonisolated static var locale: Locale { Locale(identifier: language) }

    nonisolated static func text(_ key: String, _ arguments: String...) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    nonisolated static func quantity(_ key: String, _ value: Int) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return String(format: format, locale: locale, arguments: [value])
    }

    nonisolated static func decimalQuantity(_ key: String, _ value: Double) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return String(format: format, locale: locale, arguments: [value])
    }

    /// Persist the initial choice once, so language changes never change saved units.
    nonisolated static func initializeUnits(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: "measurementUnit") == nil else { return }
        let existingInstallation = defaults.bool(forKey: "hasCompletedOnboarding")
            || defaults.object(forKey: "directionStyle") != nil
            || defaults.object(forKey: "areaMode") != nil
        let code = locale.language.languageCode?.identifier
        defaults.set(!existingInstallation && (code == "es" || code == "pt") ? "meters" : "feet",
                     forKey: "measurementUnit")
    }
}
