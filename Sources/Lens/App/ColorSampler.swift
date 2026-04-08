import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct ColorSampler {
    private let context = CIContext(options: nil)

    func style(block: RecognizedTextBlock, in image: CGImage) -> (background: OverlaySwatch, foreground: OverlaySwatch) {
        let sampled = averageColor(in: expandedRect(for: block.boundingBox), image: image)
        let useDarkText = sampled.luminance > 0.58
        let background = useDarkText ? sampled.adjusted(delta: 0.04) : sampled.adjusted(delta: -0.06)
        let foreground = useDarkText ? OverlaySwatch.black : OverlaySwatch.white
        return (background, foreground)
    }

    private func expandedRect(for rect: CGRect) -> CGRect {
        rect.insetBy(dx: -0.008, dy: -0.01).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func averageColor(in normalizedRect: CGRect, image: CGImage) -> OverlaySwatch {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let pixelRect = CGRect(
            x: normalizedRect.minX * width,
            y: (1 - normalizedRect.maxY) * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        ).integral

        guard !pixelRect.isNull, !pixelRect.isEmpty else {
            return OverlaySwatch.white
        }

        let filter = CIFilter.areaAverage()
        filter.inputImage = CIImage(cgImage: image)
        filter.extent = pixelRect

        guard let outputImage = filter.outputImage else {
            return OverlaySwatch.white
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return OverlaySwatch(
            red: Double(bitmap[0]) / 255.0,
            green: Double(bitmap[1]) / 255.0,
            blue: Double(bitmap[2]) / 255.0,
            alpha: 0.94
        )
    }
}
