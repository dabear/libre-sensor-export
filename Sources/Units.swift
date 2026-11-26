//  Units.swift — mg/dL or mmol/L for display. Everything is computed and exported in mg/dL.
import SwiftUI

enum GlucoseUnit: String, CaseIterable, Identifiable {
    case mgdl, mmol

    var id: String { rawValue }
    /// The setting's key in UserDefaults.
    static let storageKey = "glucoseUnit"
    var label: String { self == .mgdl ? "mg/dL" : "mmol/L" }
    var spoken: String { self == .mgdl ? "milligrams per deciliter" : "millimoles per liter" }

    static let mgdlPerMmol = 18.0182

    func value(_ mgdl: Double) -> Double { self == .mgdl ? mgdl : mgdl / Self.mgdlPerMmol }

    /// In the phone's number format (e.g. 5,6 in Norway).
    func format(_ mgdl: Double) -> String {
        value(mgdl).formatted(.number.precision(.fractionLength(self == .mgdl ? 0 : 1)))
    }

    func formatRate(_ mgdlPerMinute: Double) -> String {
        value(mgdlPerMinute).formatted(.number.precision(.fractionLength(self == .mgdl ? 1 : 2))
            .sign(strategy: .always()))
    }

    /// mg/dL where it's the usual unit, mmol/L elsewhere. Changeable in the app's menu.
    static var regionDefault: GlucoseUnit {
        let mgdlRegions: Set<String> = [
            "US", "FR", "DE", "AT", "BE", "LU", "IT", "ES", "PT", "PL", "JP", "KR", "IN", "IL",
            "BR", "AR", "MX", "CO", "CL", "PE", "EG", "TR", "PH", "TW", "TH", "ID", "VN",
        ]
        return mgdlRegions.contains(Locale.current.region?.identifier ?? "US") ? .mgdl : .mmol
    }
}

/// Colour by range (mg/dL): low, in range 70–180, high, very high.
func glucoseColor(_ mgdl: Double) -> Color {
    switch mgdl {
    case ..<70: return .badText
    case 70..<180: return .okText
    case 180..<250: return .warnText
    default: return .badText
    }
}

extension Color {
    /// Colours for text: darker in light mode, so text keeps about 4.5:1 contrast or more
    /// (system green and orange on white are near 2:1). Dark mode keeps the system colours.
    static let okText = adaptive(light: UIColor(red: 0.10, green: 0.50, blue: 0.20, alpha: 1), dark: .systemGreen)
    static let warnText = adaptive(light: UIColor(red: 0.70, green: 0.36, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let badText = adaptive(light: UIColor(red: 0.75, green: 0.13, blue: 0.13, alpha: 1), dark: .systemRed)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// "4d 6h 7m · 6127 min" read aloud as days, hours and minutes, not letters or metres.
func spoken(_ text: String) -> String {
    var s = text
    for (pattern, word) in [(#"(\d+)d\b"#, "$1 days"), (#"(\d+)h\b"#, "$1 hours"), (#"(\d+)m\b"#, "$1 minutes"),
                            (#"\bmin\b"#, "minutes"), (#"\s·\s"#, ", ")] {
        s = s.replacingOccurrences(of: pattern, with: word, options: .regularExpression)
    }
    return s
}

/// Trend arrow and words from the rate in mg/dL per minute.
func trendArrow(_ rate: Double?) -> (symbol: String, words: String) {
    guard let rate else { return ("questionmark", "trend unknown") }
    switch rate {
    case ..<(-2): return ("arrow.down", "falling quickly")
    case -2 ..< -1: return ("arrow.down.right", "falling")
    case -1...1: return ("arrow.right", "steady")
    case 1...2: return ("arrow.up.right", "rising")
    default: return ("arrow.up", "rising quickly")
    }
}
