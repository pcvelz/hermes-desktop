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

struct HiddenHermesProfilePreference: Codable, Hashable, Identifiable {
    let hostConnectionFingerprint: String
    let profileName: String

    var id: String {
        "\(hostConnectionFingerprint)|\(profileName)"
    }
}
