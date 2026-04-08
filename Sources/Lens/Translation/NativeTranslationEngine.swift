import Foundation
import NaturalLanguage
@preconcurrency import Translation

@MainActor
final class NativeTranslationEngine {
    private var cache: [String: String] = [:]

    func clearCache() {
        cache.removeAll()
    }

    func translate(
        blocks: [RecognizedTextBlock],
        targetLanguage: Locale.Language
    ) async -> [RenderedTextBlock] {
        guard !blocks.isEmpty else {
            return []
        }

        var renderedByID: [UUID: RenderedTextBlock] = Dictionary(
            uniqueKeysWithValues: blocks.map { block in
                (
                    block.id,
                    RenderedTextBlock(
                        sourceText: block.sourceText,
                        translatedText: block.sourceText,
                        boundingBox: block.boundingBox,
                        isFallback: true,
                        background: .white,
                        foreground: .black,
                        lineCount: block.lineCount
                    )
                )
            }
        )

        // Check cache for already-translated phrases
        for block in blocks {
            if let cached = cache[block.sourceText] {
                renderedByID[block.id] = RenderedTextBlock(
                    sourceText: block.sourceText,
                    translatedText: cached,
                    boundingBox: block.boundingBox,
                    isFallback: false,
                    background: .white,
                    foreground: .black,
                    lineCount: block.lineCount
                )
            }
        }

        let candidates = blocks.filter { shouldAttemptTranslation($0) && cache[$0.sourceText] == nil }
        let grouped = Dictionary(grouping: candidates, by: detectLanguage)

        for (language, group) in grouped {
            guard let language else {
                continue
            }

            let sourceLocale = Locale.Language(identifier: language.rawValue)
            let session = TranslationSession(installedSource: sourceLocale, target: targetLanguage)

            let requests = group.map { block in
                TranslationSession.Request(
                    sourceText: block.sourceText,
                    clientIdentifier: block.id.uuidString
                )
            }

            do {
                nonisolated(unsafe) let sendableRequests = requests
                let responses = try await session.translations(from: sendableRequests)
                for response in responses {
                    guard
                        let identifier = response.clientIdentifier,
                        let uuid = UUID(uuidString: identifier),
                        let block = group.first(where: { $0.id == uuid })
                    else {
                        continue
                    }

                    cache[block.sourceText] = response.targetText
                    renderedByID[uuid] = RenderedTextBlock(
                        sourceText: block.sourceText,
                        translatedText: response.targetText,
                        boundingBox: block.boundingBox,
                        isFallback: false,
                        background: .white,
                        foreground: .black,
                        lineCount: block.lineCount
                    )
                }
            } catch {
                continue
            }
        }

        return blocks.compactMap { renderedByID[$0.id] }
    }

    private func shouldAttemptTranslation(_ block: RecognizedTextBlock) -> Bool {
        let stripped = block.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let letterCount = stripped.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 2
    }

    private func detectLanguage(for block: RecognizedTextBlock) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(block.sourceText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first, confidence >= 0.4 else {
            return nil
        }
        return language
    }
}
