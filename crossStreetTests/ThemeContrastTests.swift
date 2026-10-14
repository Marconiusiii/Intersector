import SwiftUI
import UIKit
import Testing
@testable import Intersector

@MainActor
struct ThemeContrastTests {
    private func rgb(_ color: Color, _ style: UIUserInterfaceStyle, highContrast: Bool = false) -> [Double] {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(accessibilityContrast: highContrast ? .high : .normal)
        ])
        var components = [Double]()
        traits.performAsCurrent {
            let resolved = UIColor(color).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            #expect(a == 1)
            components = [Double(r), Double(g), Double(b)]
        }
        return components
    }

    private func contrast(_ foreground: [Double], _ background: [Double]) -> Double {
        func luminance(_ rgb: [Double]) -> Double {
            zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let value = pair.0
                return sum + pair.1 * (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
            }
        }
        let f = luminance(foreground), b = luminance(background)
        return (max(f, b) + 0.05) / (min(f, b) + 0.05)
    }

    @Test(arguments: [1, 2], [false, true])
    func textAndIndicatorsMeetContrast(styleValue: Int, highContrast: Bool) {
        let style = UIUserInterfaceStyle(rawValue: styleValue)!
        let surfaces: [Color] = [.crossBg, .crossSettingsHeader, .crossSettingsRow, .crossSettingsHelper]
        for surface in surfaces {
            for text: Color in [.crossText, .crossAccent] {
                #expect(contrast(rgb(text, style, highContrast: highContrast), rgb(surface, style, highContrast: highContrast)) >= 4.5)
            }
        }
        for text: Color in [.crossInv, .white] {
            #expect(contrast(rgb(text, style), rgb(.crossPanel, style)) >= 4.5)
        }
        #expect(contrast(rgb(.crossPanelAccent, style), rgb(.crossPanel, style)) >= 3)
        for fill: Color in [.crossBtn, .crossScanIdle, .crossScanActive] {
            #expect(contrast(rgb(.crossButtonText, style), rgb(fill, style)) >= 4.5)
        }
        #expect(contrast(rgb(.crossChevron, style), rgb(.crossBtn, style)) >= 3)
        // Light buttons use a dark outline; dark appearance uses the bright fill.
        let boundary: Color = style == .light ? .crossButtonStrongBorder : .crossBtn
        #expect(contrast(rgb(boundary, style), rgb(.crossBg, style)) >= 3)
    }

    @Test func darkPalettePreservesBrightControls() {
        let yellow = rgb(.crossControlTint, .dark)
        for (actual, expected) in zip(yellow, [1.0, 0.8, 0.18]) {
            #expect(abs(actual - expected) < 0.001)
        }
        let orange = rgb(.crossScanActive, .dark)
        for (actual, expected) in zip(orange, [1.0, 0.55, 0.12]) {
            #expect(abs(actual - expected) < 0.001)
        }
        // The light-mode control tint still contrasts with its white thumb.
        #expect(contrast(rgb(.white, .light), rgb(.crossControlTint, .light)) >= 3)
    }

    @Test(arguments: [1, 2])
    func pressedScanLabelKeepsContrast(styleValue: Int) {
        let style = UIUserInterfaceStyle(rawValue: styleValue)!
        let text = rgb(.crossButtonText, style)
        for fill: Color in [.crossScanIdle, .crossScanActive] {
            let background = rgb(fill, style)
            let pressed = zip(text, background).map { 0.82 * $0 + 0.18 * $1 }
            #expect(contrast(pressed, background) >= 4.5)
        }
    }

    @Test(arguments: [1, 2])
    func accentAssetMatchesTextAccent(styleValue: Int) throws {
        let style = UIUserInterfaceStyle(rawValue: styleValue)!
        let traits = UITraitCollection(userInterfaceStyle: style)
        let asset = try #require(UIColor(named: "AccentColor", in: Bundle.main, compatibleWith: traits))
        let expected = rgb(.crossAccent, style)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #expect(asset.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
        for (actual, wanted) in zip([Double(r), Double(g), Double(b)], expected) {
            #expect(abs(actual - wanted) < 0.003)
        }
    }
}
