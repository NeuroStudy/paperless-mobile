import Vision
import CoreImage
import Foundation

@available(iOS 11.0, *)
enum VisionRectangleDetector {
    private static func detect(_ image: CIImage, outputSize: CGSize, maxEdge: CGFloat,
                               completion: @escaping (Quadrilateral?) -> Void) {
        let scale = min(1, maxEdge / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let handler = VNImageRequestHandler(ciImage: small, orientation: .up, options: [:])
        var observations = [VNRectangleObservation]()
        if #available(iOS 15.0, *) {
            let segmentation = VNDetectDocumentSegmentationRequest()
            if (try? handler.perform([segmentation])) != nil {
                observations = (segmentation.results ?? []).filter { acceptable($0) }
            }
        }
        if observations.isEmpty {
            let request = VNDetectRectanglesRequest()
            request.minimumConfidence = 0.65
            request.maximumObservations = 12
            request.minimumAspectRatio = 0.08
            request.minimumSize = 0.08
            request.quadratureTolerance = 35
            do { try handler.perform([request]); observations = (request.results ?? []).filter { acceptable($0) } }
            catch { completion(nil); return }
        }
        let best = observations.max { score($0) < score($1) }
        completion(best.map { Quadrilateral(rectangleObservation: $0).applying(CGAffineTransform(scaleX: outputSize.width, y: outputSize.height)) })
    }

    private static func acceptable(_ observation: VNRectangleObservation) -> Bool {
        let quad = Quadrilateral(rectangleObservation: observation)
        let borders = quad.scanPoints.filter { $0.x < 0.005 || $0.y < 0.005 || $0.x > 0.995 || $0.y > 0.995 }.count
        return observation.confidence >= 0.65 && quad.scanIsValid && (0.06...0.97).contains(quad.scanArea) && borders <= 2
    }
    private static func score(_ observation: VNRectangleObservation) -> CGFloat {
        let quad = Quadrilateral(rectangleObservation: observation)
        return CGFloat(observation.confidence) * 0.7 + sqrt(quad.scanArea) * 0.3
    }

    static func rectangle(forPixelBuffer buffer: CVPixelBuffer, completion: @escaping (Quadrilateral?) -> Void) {
        let image = CIImage(cvPixelBuffer: buffer)
        detect(image, outputSize: image.extent.size, maxEdge: 960, completion: completion)
    }
    static func rectangle(forImage image: CIImage, completion: @escaping (Quadrilateral?) -> Void) {
        detect(image, outputSize: image.extent.size, maxEdge: 1600, completion: completion)
    }
    static func rectangle(forImage image: CIImage, orientation: CGImagePropertyOrientation,
                          completion: @escaping (Quadrilateral?) -> Void) {
        let upright = image.oriented(orientation)
        detect(upright, outputSize: upright.extent.size, maxEdge: 1600, completion: completion)
    }
}
