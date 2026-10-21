import XCTest
import UIKit
@testable import WeScan

final class ColorEnhancementTests: XCTestCase {
    private func page(loss: Double) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; return format
        }())
        return renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            for y in stride(from: 100, to: 650, by: 50) {
                ("Readable document 0123456789" as NSString).draw(at: CGPoint(x: 60, y: y),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.darkGray])
            }
            UIColor(white: 240 / 255, alpha: 1).setFill(); context.fill(CGRect(x: 300, y: 650, width: 100, height: 80))
            let colors = [UIColor(white: 0, alpha: CGFloat(loss)).cgColor, UIColor.clear.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: ScanColorEnhancement.colorSpace, colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 0), options: [])
        }
    }

    private func sample(_ image: UIImage, x: Int, y: Int) -> Double {
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { data in
            ScanColorEnhancement.context.render(CIImage(cgImage: image.cgImage!), toBitmap: data.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: ScanColorEnhancement.colorSpace)
        }
        return Double(Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
    }

    func testShadowGradesAndCachedPreview() throws {
        for loss in [0.0, 0.05, 0.15, 0.35, 0.6, 0.8] {
            let image = page(loss: loss)
            let profile = ScanProcessing.prepareEnhancement(image, quad: ScanProcessing.fullImage)
            let output = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 4096, profile: profile))
            let preview = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 400, profile: profile))
            XCTAssertGreaterThan(sample(output, x: 30, y: 400), loss <= 0.6 ? 242 : 150)
            XCTAssertLessThan(abs(sample(output, x: 30, y: 400) - sample(preview, x: 15, y: 200)), 5)
            XCTAssertLessThanOrEqual(profile.background!.extent.width, 768)
            XCTAssertLessThanOrEqual(profile.background!.extent.height, 768)
        }
    }

    func testToggleAndOriginalDoNotApplyShadowCorrection() throws {
        let image = page(loss: 0.6)
        let on = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 800))
        let off = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 800, reduceShadows: false))
        let original = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .original, maxEdge: 800))
        XCTAssertGreaterThan(sample(on, x: 30, y: 400) - sample(off, x: 30, y: 400), 50)
        XCTAssertLessThan(sample(original, x: 30, y: 400), 160)
        XCTAssertLessThan(sample(on, x: 350, y: 100), 247)
    }

    func testFaintPrintedPanelStaysVisible() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor(white: 240.0 / 255, alpha: 1).setFill(); context.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        }
        let output = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 200))
        XCTAssertLessThanOrEqual(sample(output, x: 100, y: 100), 240)
    }

    func testDarkImageUsesSameConservativeToneWithToggleOnOrOff() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { context in
            UIColor(white: 35.0 / 255, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        let on = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 200))
        let off = try XCTUnwrap(ScanProcessing.render(image, quad: ScanProcessing.fullImage, turns: 0, filter: .enhanced, maxEdge: 200, reduceShadows: false))
        XCTAssertEqual(sample(on, x: 100, y: 100), sample(off, x: 100, y: 100), accuracy: 1)
    }

    func testCompressedBlueTextKeepsWhiteSpaceNeutral() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor(red: 250.0 / 255, green: 240.0 / 255, blue: 220.0 / 255, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            for y in stride(from: 240, through: 420, by: 30) {
                ("Colored text and readable fine print" as NSString).draw(at: CGPoint(x: 60, y: y),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20),
                        .foregroundColor: UIColor(red: 45.0 / 255, green: 100.0 / 255, blue: 175.0 / 255, alpha: 1)])
            }
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor.clear.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: ScanColorEnhancement.colorSpace, colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 0), options: [])
        }
        let compressed = try XCTUnwrap(UIImage(data: XCTUnwrap(image.jpegData(compressionQuality: 0.78))))
        let output = try XCTUnwrap(ScanProcessing.render(compressed, quad: ScanProcessing.fullImage,
            turns: 0, filter: .enhanced, maxEdge: 800))
        for y in stride(from: 240, through: 420, by: 30) {
            XCTAssertGreaterThan(sample(output, x: 100, y: output.cgImage!.height - 1 - (y + 27)), 250)
        }
    }
}
