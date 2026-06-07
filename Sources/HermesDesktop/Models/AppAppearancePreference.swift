import AppKit
import SwiftUI

enum AppAppearancePreference: String, CaseIterable, Codable, Identifiable {
    case system
    case dark
    case light

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .light:
            return NSAppearance(named: .aqua)
        }
    }

    @MainActor
    func applyToApplication() {
        let appearance = nsAppearance
        NSApplication.shared.appearance = appearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance
            window.viewsNeedDisplay = true
        }
    }
}

enum TerminalFontPreference {
    static let defaultSize: Double = 13
    static let minimumSize: Double = 10
    static let maximumSize: Double = 20

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimumSize), maximumSize)
    }
}

enum TerminalFontFamilyPreference: String, CaseIterable, Codable, Identifiable {
    case sfMono
    case menlo
    case monaco

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .sfMono:
            return "SF Mono"
        case .menlo:
            return "Menlo"
        case .monaco:
            return "Monaco"
        }
    }

    func font(size: Double) -> NSFont {
        let clampedSize = CGFloat(TerminalFontPreference.clamped(size))
        switch self {
        case .sfMono:
            return NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo", size: clampedSize) ?? NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
        case .monaco:
            return NSFont(name: "Monaco", size: clampedSize) ?? NSFont.monospacedSystemFont(ofSize: clampedSize, weight: .regular)
        }
    }
}

enum AppWindowOpacityPreference {
    static let defaultValue: Double = 1.0
    static let minimumValue: Double = 0.58
    static let maximumValue: Double = 1.0

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimumValue), maximumValue)
    }
}

struct HiddenHermesProfilePreference: Codable, Hashable, Identifiable {
    let hostConnectionFingerprint: String
    let profileName: String

    var id: String {
        "\(hostConnectionFingerprint)|\(profileName)"
    }
}
