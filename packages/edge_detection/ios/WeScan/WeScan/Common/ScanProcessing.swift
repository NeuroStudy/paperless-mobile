import CoreImage
import UIKit

enum ScanFilter: Int, CaseIterable {
    case original, enhanced, grayscale, blackWhite
    var title: String {
        let values = ["Original", "Enhanced color", "Grayscale", "Black & white"]
        return scanText("paperless.filter.\(rawValue)", values[rawValue])
    }
}

func scanText(_ key: String, _ fallback: String) -> String {
    return NSLocalizedString(key, tableName: nil, bundle: Bundle(for: ImageScannerController.self), value: fallback, comment: "Document scanner")
}

enum ScanProcessing {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let fullImage = Quadrilateral(topLeft: .zero, topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))

    static func upright(_ image: UIImage, maxEdge: CGFloat = 4096) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var input = CIImage(cgImage: cgImage).oriented(CGImagePropertyOrientation(image.imageOrientation))
        let scale = min(1, maxEdge / max(input.extent.width, input.extent.height))
        if scale < 1 { input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let output = context.createCGImage(input, from: input.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    static func prepareEnhancement(_ image: UIImage, quad: Quadrilateral) -> ScanEnhancementProfile {
        guard let input = cropped(image, quad: quad, maxEdge: ScanColorEnhancement.analysisEdge) else { return .conservative }
        return ScanColorEnhancement.analyze(input)
    }

    private static func cropped(_ image: UIImage, quad: Quadrilateral, maxEdge: CGFloat) -> CIImage? {
        guard quad.scanIsValid, let cgImage = image.cgImage else { return nil }
        var input = CIImage(cgImage: cgImage)
        let size = input.extent.size
        let points = quad.scanPoints.map { CGPoint(x: $0.x * (size.width - 1), y: (1 - $0.y) * (size.height - 1)) }
        input = input.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: points[0]), "inputTopRight": CIVector(cgPoint: points[1]),
            "inputBottomRight": CIVector(cgPoint: points[2]), "inputBottomLeft": CIVector(cgPoint: points[3])])
        let scale = min(1, maxEdge / max(input.extent.width, input.extent.height))
        if scale < 1 { input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        return input
    }

    static func render(_ image: UIImage, quad: Quadrilateral, turns: Int, filter: ScanFilter, maxEdge: CGFloat,
                       reduceShadows: Bool = true, profile: ScanEnhancementProfile? = nil) -> UIImage? {
        guard var input = cropped(image, quad: quad, maxEdge: maxEdge) else { return nil }
        switch filter {
        case .original: break
        case .enhanced:
            if reduceShadows {
                guard let enhanced = ScanColorEnhancement.apply(input, profile: profile ?? ScanColorEnhancement.analyze(input)) else { return nil }
                input = enhanced
            } else {
                input = input.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputBrightnessKey: -0.04])
            }
        case .grayscale:
            input = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .blackWhite:
            let gray = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            let radius = max(1, min(gray.extent.width, gray.extent.height) / 80)
            let local = gray.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: gray.extent)
            guard let kernel = thresholdKernel,
                let result = kernel.apply(extent: gray.extent, arguments: [gray, local]) else { return nil }
            input = result
        }
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        input = input.oriented(orientations[(turns % 4 + 4) % 4])
        let renderer = filter == .enhanced ? ScanColorEnhancement.context : context
        guard let output = renderer.createCGImage(input, from: input.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    private static let thresholdKernel = CIColorKernel(source: """
        kernel vec4 threshold(__sample pixel, __sample background) {
            float value = step(background.r - 0.035, pixel.r);
            return vec4(value, value, value, 1.0);
        }
        """)
}

extension Quadrilateral {
    var scanPoints: [CGPoint] { return [topLeft, topRight, bottomRight, bottomLeft] }
    var scanArea: CGFloat {
        let points = scanPoints
        return abs((0..<4).reduce(CGFloat(0)) { total, i in
            let next = points[(i + 1) % 4]
            return total + points[i].x * next.y - next.x * points[i].y
        }) / 2
    }
    var scanIsValid: Bool {
        let p = scanPoints
        guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }), scanArea > 0.005 else { return false }
        let cross = (0..<4).map { i -> CGFloat in
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return cross.allSatisfy { $0 > 0.00001 } || cross.allSatisfy { $0 < -0.00001 }
    }
    func scanDistance(to other: Quadrilateral) -> CGFloat {
        return zip(scanPoints, other.scanPoints).map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) }.max() ?? 1
    }
}
