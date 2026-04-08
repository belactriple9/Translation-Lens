import CoreGraphics
import Foundation
import Vision

enum OCRError: LocalizedError {
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .recognitionFailed:
            return "OCR failed while processing the captured frame."
        }
    }
}

struct OCRService {
    func recognize(in image: CGImage) async throws -> [RecognizedTextBlock] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let results = (request.results ?? [])
                        .compactMap { observation -> RecognizedTextBlock? in
                            guard
                                let candidate = observation.topCandidates(1).first,
                                !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else {
                                return nil
                            }

                            return RecognizedTextBlock(
                                sourceText: candidate.string,
                                boundingBox: observation.boundingBox,
                                confidence: candidate.confidence,
                                lineCount: 1
                            )
                        }
                        .sorted { lhs, rhs in
                            let yDelta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                            if yDelta > 0.02 {
                                return lhs.boundingBox.midY > rhs.boundingBox.midY
                            }
                            return lhs.boundingBox.minX < rhs.boundingBox.minX
                        }

                    continuation.resume(returning: mergeParagraphs(in: results))
                } catch {
                    continuation.resume(throwing: OCRError.recognitionFailed)
                }
            }
        }
    }

    private func mergeParagraphs(in blocks: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        guard !blocks.isEmpty else {
            return []
        }

        var merged: [RecognizedTextBlock] = []
        var currentGroup: [RecognizedTextBlock] = [blocks[0]]

        for block in blocks.dropFirst() {
            if shouldMerge(block, into: currentGroup) {
                currentGroup.append(block)
            } else {
                merged.append(collapse(group: currentGroup))
                currentGroup = [block]
            }
        }

        merged.append(collapse(group: currentGroup))
        return merged
    }

    private func shouldMerge(_ candidate: RecognizedTextBlock, into group: [RecognizedTextBlock]) -> Bool {
        guard let last = group.last else {
            return false
        }

        let verticalGap = last.boundingBox.minY - candidate.boundingBox.maxY
        let leadingDelta = abs(last.boundingBox.minX - candidate.boundingBox.minX)
        let widthRatio = min(last.boundingBox.width, candidate.boundingBox.width) / max(last.boundingBox.width, candidate.boundingBox.width)
        let horizontalOverlap = overlap(
            last.boundingBox.minX...last.boundingBox.maxX,
            candidate.boundingBox.minX...candidate.boundingBox.maxX
        )

        return verticalGap >= -0.01
            && verticalGap <= 0.06
            && (leadingDelta <= 0.10 || horizontalOverlap >= 0.22)
            && widthRatio >= 0.12
    }

    private func collapse(group: [RecognizedTextBlock]) -> RecognizedTextBlock {
        let sorted = group.sorted { lhs, rhs in
            let yDelta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if yDelta > 0.02 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        var lines: [[RecognizedTextBlock]] = []
        for block in sorted {
            if let last = lines.indices.last,
               abs(lines[last][0].boundingBox.midY - block.boundingBox.midY) <= 0.02 {
                lines[last].append(block)
            } else {
                lines.append([block])
            }
        }

        let text = lines
            .map { line in
                line
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map(\.sourceText)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")

        let union = sorted
            .map(\.boundingBox)
            .reduce(sorted[0].boundingBox) { partialResult, rect in
                partialResult.union(rect)
            }

        let confidence = sorted.map(\.confidence).reduce(0, +) / Float(sorted.count)

        return RecognizedTextBlock(
            sourceText: text,
            boundingBox: union,
            confidence: confidence,
            lineCount: lines.count
        )
    }

    private func overlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }
}
