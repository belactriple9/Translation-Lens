import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case missingWindow
    case invalidWindowNumber(Int)
    case captureFailed
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .missingWindow:
            return "The overlay window is not attached yet."
        case .invalidWindowNumber(let number):
            return "The overlay window number is not usable yet (\(number))."
        case .captureFailed:
            return "Capturing the screen below the overlay failed."
        case .noDisplay:
            return "No display found for the overlay window."
        }
    }
}

struct CaptureSnapshot {
    let image: CGImage
    let rectInScreen: CGRect
}

@MainActor
final class ScreenCaptureEngine {
    func hasPermission(promptIfNeeded: Bool) -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted && promptIfNeeded {
            CGRequestScreenCaptureAccess()
        }
        return granted
    }

    func captureBelow(window: NSWindow) async throws -> CaptureSnapshot {
        guard let contentView = window.contentView else {
            throw ScreenCaptureError.missingWindow
        }

        let windowNumber = window.windowNumber
        guard windowNumber > 0 else {
            throw ScreenCaptureError.invalidWindowNumber(windowNumber)
        }

        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        let contentRectInScreen = window.convertToScreen(contentRectInWindow).integral

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: { display in
            display.frame.intersects(contentRectInScreen)
        }) else {
            throw ScreenCaptureError.noDisplay
        }

        let excludedWindows = content.windows.filter { $0.windowID == CGWindowID(windowNumber) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let displayFrame = display.frame
        let sourceRect = CGRect(
            x: contentRectInScreen.minX - displayFrame.minX,
            y: displayFrame.height - (contentRectInScreen.maxY - displayFrame.minY),
            width: contentRectInScreen.width,
            height: contentRectInScreen.height
        )

        let scaleFactor = window.screen?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(contentRectInScreen.width * scaleFactor)
        config.height = Int(contentRectInScreen.height * scaleFactor)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        return CaptureSnapshot(image: image, rectInScreen: contentRectInScreen)
    }
}
