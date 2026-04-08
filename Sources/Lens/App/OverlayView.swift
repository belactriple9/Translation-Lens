import CoreGraphics
import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    captureLayer(size: proxy.size)
                    translationLayer(size: proxy.size)
                }
                .animation(.easeInOut(duration: 0.2), value: model.translatedBlocks.map(\.id))
            }

            statusOverlay
        }
        .overlay(borderOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            WindowAccessor { window in
                model.attach(window: window)
            }
        )
        .frame(minWidth: 420, minHeight: 280)
    }

    @ViewBuilder
    private func captureLayer(size: CGSize) -> some View {
        if let image = model.frameImage {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.94, green: 0.95, blue: 0.97),
                        Color(red: 0.87, green: 0.90, blue: 0.94),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.secondary)
                    Text("Drag this window over any text to translate it")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Grab the edges to move or resize")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .padding()
            }
    }

    private func translationLayer(size: CGSize) -> some View {
        ForEach(model.translatedBlocks.filter { !$0.isFallback }) { block in
            translationBlockView(block: block, containerSize: size)
        }
    }

    private func translationBlockView(block: RenderedTextBlock, containerSize: CGSize) -> some View {
        let blockRect = rect(for: block.boundingBox, in: containerSize)
        let lines = max(block.lineCount, 1)
        let textSize = fontSize(for: blockRect, lineCount: lines)
        let padding: CGFloat = 8
        let maxAvailableWidth = containerSize.width - padding * 2
        let overlayWidth = min(max(blockRect.width + 14, 60), maxAvailableWidth)
        let overlayHeight = max(blockRect.height + 6, 20)

        let idealX = blockRect.minX + overlayWidth / 2
        let clampedX = min(max(idealX, overlayWidth / 2 + padding), containerSize.width - overlayWidth / 2 - padding)
        let idealY = blockRect.minY + overlayHeight / 2
        let clampedY = max(idealY, padding)

        return Text(formattedLabel(for: block))
            .font(.system(size: textSize, weight: .semibold, design: .rounded))
            .foregroundStyle(swatchColor(block.foreground))
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(
                width: overlayWidth,
                alignment: .topLeading
            )
            .frame(minHeight: overlayHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(swatchColor(block.background))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(swatchColor(block.foreground).opacity(0.08), lineWidth: 0.5)
            )
            .position(
                x: clampedX,
                y: clampedY
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if case .error(let message) = model.status {
            statusBadge(message, tint: .yellow)
                .padding(12)
        } else if model.isPaused {
            statusBadge("Paused", tint: .blue)
                .padding(12)
        } else if case .idle(let message) = model.status, model.frameImage != nil {
            statusBadge(message, tint: Color(white: 0.92))
                .padding(12)
        }
    }

    private var borderOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
        }
    }

    private func statusBadge(_ message: String, tint: Color) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.92))
            )
    }

    private func swatchColor(_ swatch: OverlaySwatch) -> Color {
        Color(
            red: swatch.red,
            green: swatch.green,
            blue: swatch.blue,
            opacity: swatch.alpha
        )
    }

    private func formattedLabel(for block: RenderedTextBlock) -> String {
        let translated = reflow(block.translatedText, targetLineCount: max(block.lineCount, 1))

        if model.settings.showSourceText && block.translatedText != block.sourceText {
            let source = reflow(block.sourceText, targetLineCount: max(block.lineCount, 1))
            return "\(translated)\n\(source)"
        }

        return translated
    }

    private func rect(for boundingBox: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: boundingBox.minX * size.width,
            y: (1 - boundingBox.maxY) * size.height,
            width: boundingBox.width * size.width,
            height: boundingBox.height * size.height
        )
    }

    private func fontSize(for rect: CGRect, lineCount: Int) -> CGFloat {
        let perLine = rect.height / CGFloat(max(lineCount, 1))
        return min(max(perLine * 0.55, 9), 16)
    }

    private func reflow(_ text: String, targetLineCount: Int) -> String {
        let words = text
            .split(whereSeparator: \.isNewline)
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map(String.init)

        guard targetLineCount > 1, words.count > targetLineCount else {
            return text.replacingOccurrences(of: "\n", with: " ")
        }

        var lines = Array(repeating: [String](), count: targetLineCount)
        let totalCharacters = words.reduce(0) { $0 + $1.count }
        let targetCharactersPerLine = max(totalCharacters / targetLineCount, 1)

        var currentLine = 0
        var currentCount = 0

        for word in words {
            if currentLine < targetLineCount - 1,
               currentCount >= targetCharactersPerLine,
               !lines[currentLine].isEmpty
            {
                currentLine += 1
                currentCount = 0
            }

            lines[currentLine].append(word)
            currentCount += word.count + 1
        }

        return lines
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }
            .joined(separator: "\n")
    }
}
