import CoreGraphics
import Foundation

struct RecognizedTextBlock: Identifiable, Hashable {
    let id = UUID()
    let sourceText: String
    let boundingBox: CGRect
    let confidence: Float
    let lineCount: Int
}

struct RenderedTextBlock: Identifiable, Hashable {
    let id = UUID()
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect
    let isFallback: Bool
    let background: OverlaySwatch
    let foreground: OverlaySwatch
    let lineCount: Int
}

enum OverlayStatus: Equatable {
    case idle(String)
    case running(String)
    case error(String)

    var message: String {
        switch self {
        case .idle(let message), .running(let message), .error(let message):
            return message
        }
    }
}

struct TranslationSettings: Equatable {
    var refreshInterval = 0.8
    var showSourceText = false
    var targetLanguage: TargetLanguage = .system
}

enum TargetLanguage: String, CaseIterable, Equatable, Identifiable {
    case system
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case arabic = "ar"
    case russian = "ru"
    case hindi = "hi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Language"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .chinese: return "Chinese (Simplified)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .arabic: return "Arabic"
        case .russian: return "Russian"
        case .hindi: return "Hindi"
        }
    }

    var locale: Locale.Language {
        switch self {
        case .system:
            return Locale.current.language
        default:
            return Locale.Language(identifier: rawValue)
        }
    }
}

struct OverlaySwatch: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let white = OverlaySwatch(red: 1, green: 1, blue: 1, alpha: 0.96)
    static let black = OverlaySwatch(red: 0, green: 0, blue: 0, alpha: 0.92)

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    func adjusted(delta: Double) -> OverlaySwatch {
        OverlaySwatch(
            red: clamp(red + delta),
            green: clamp(green + delta),
            blue: clamp(blue + delta),
            alpha: alpha
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
