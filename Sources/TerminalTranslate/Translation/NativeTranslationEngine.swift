import Foundation
import NaturalLanguage
@preconcurrency import Translation

@MainActor
struct NativeTranslationEngine {
    func translate(
        blocks: [RecognizedTextBlock],
        using session: TranslationSession
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
                        foreground: .black
                    )
                )
            }
        )

        let candidates = blocks.filter(shouldAttemptTranslation)
        let grouped = Dictionary(grouping: candidates, by: detectLanguage)

        for (language, group) in grouped {
            guard language != nil else {
                continue
            }

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

                    renderedByID[uuid] = RenderedTextBlock(
                        sourceText: block.sourceText,
                        translatedText: response.targetText,
                        boundingBox: block.boundingBox,
                        isFallback: false,
                        background: .white,
                        foreground: .black
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
        let wordCount = stripped.split(whereSeparator: \.isWhitespace).count
        return letterCount >= 6 && wordCount >= 2
    }

    private func detectLanguage(for block: RecognizedTextBlock) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(block.sourceText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first, confidence >= 0.35 else {
            return nil
        }
        return language
    }
}
