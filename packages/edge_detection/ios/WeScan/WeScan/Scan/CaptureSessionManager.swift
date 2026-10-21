import AVFoundation
import CoreImage
import QuartzCore
import UIKit

protocol RectangleDetectionDelegateProtocol: NSObjectProtocol {
    func didStartCapturingPicture(for captureSessionManager: CaptureSessionManager)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didDetectQuad quad: Quadrilateral?, _ imageSize: CGSize)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didCapturePicture picture: UIImage, withQuad quad: Quadrilateral?)
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didFailWithError error: Error)
}

/** All session state and Vision work are confined to one queue. */
final class CaptureSessionManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "paperless.scanner.camera", qos: .userInitiated)
    weak var delegate: RectangleDetectionDelegateProtocol?
    private var detecting = false
    private var capturing = false
    private var lastFrame: TimeInterval = 0
    private var lastSeen: TimeInterval = 0
    private var anchor: Quadrilateral?
    private var smoothed: Quadrilateral?
    private var stableSince: TimeInterval = 0

    init?(videoPreviewLayer: AVCaptureVideoPreviewLayer, delegate: RectangleDetectionDelegateProtocol? = nil) {
        self.delegate = delegate
        super.init()
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        CaptureSession.current.device = device
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(output) else { session.commitConfiguration(); return nil }
        session.addInput(input); session.addOutput(video); session.addOutput(output)
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        output.isHighResolutionCaptureEnabled = true
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        video.setSampleBufferDelegate(self, queue: queue)
        videoPreviewLayer.session = session
        videoPreviewLayer.videoGravity = .resizeAspect
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async {
                self.detecting = true; self.capturing = false; self.anchor = nil; self.smoothed = nil; self.lastFrame = 0
                if !self.session.isRunning { self.session.startRunning() }
            }
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in if granted { self?.start() } else { self?.fail(ImageScannerControllerError.authorization) } }
        default: fail(ImageScannerControllerError.authorization)
        }
    }
    func stop() { queue.async { self.detecting = false; if self.session.isRunning { self.session.stopRunning() } } }

    func capturePhoto() {
        queue.async {
            guard !self.capturing, let connection = self.output.connection(with: .video), connection.isActive else { return }
            self.capturing = true; self.detecting = false
            CaptureSession.current.setImageOrientation()
            let settings = AVCapturePhotoSettings()
            settings.isHighResolutionPhotoEnabled = true
            self.output.capturePhoto(with: settings, delegate: self)
            DispatchQueue.main.async { self.delegate?.didStartCapturingPicture(for: self) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard detecting, !capturing, now - lastFrame >= 0.125,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if now - lastFrame > 0.3 { anchor = nil; smoothed = nil }
        lastFrame = now
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        VisionRectangleDetector.rectangle(forPixelBuffer: buffer) { quad in
            guard let quad = quad else {
                if now - self.lastSeen > 0.25 {
                    self.anchor = nil; self.smoothed = nil
                    DispatchQueue.main.async { self.delegate?.captureSessionManager(self, didDetectQuad: nil, size) }
                }
                return
            }
            self.lastSeen = now
            let normalized = quad.applying(CGAffineTransform(scaleX: 1 / size.width, y: 1 / size.height))
            if self.anchor == nil || self.anchor!.scanDistance(to: normalized) > 0.015 {
                self.anchor = normalized; self.stableSince = now
            }
            let old = self.smoothed ?? normalized
            let blended = zip(old.scanPoints, normalized.scanPoints).map { CGPoint(x: $0.0.x * 0.55 + $0.1.x * 0.45, y: $0.0.y * 0.55 + $0.1.y * 0.45) }
            self.smoothed = Quadrilateral(topLeft: blended[0], topRight: blended[1], bottomRight: blended[2], bottomLeft: blended[3])
            let stable = now - self.stableSince >= 0.7
            let display = stable ? nil : self.smoothed?.applying(CGAffineTransform(scaleX: size.width, y: size.height)).toCartesian(withHeight: size.height)
            DispatchQueue.main.async { self.delegate?.captureSessionManager(self, didDetectQuad: display, size) }
            if stable && CaptureSession.current.isAutoScanEnabled && !CaptureSession.current.isEditing { self.capturePhoto() }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { fail(error); return }
        guard let data = photo.fileDataRepresentation() else { fail(ImageScannerControllerError.capture); return }
        queue.async {
            guard let image = UIImage(data: data), let upright = ScanProcessing.upright(image),
                  let cgImage = upright.cgImage else { self.fail(ImageScannerControllerError.capture); return }
            CaptureSession.current.isEditing = true
            VisionRectangleDetector.rectangle(forImage: CIImage(cgImage: cgImage)) { quad in
                let screenQuad = quad?.toCartesian(withHeight: upright.size.height)
                DispatchQueue.main.async { self.delegate?.captureSessionManager(self, didCapturePicture: upright, withQuad: screenQuad) }
            }
        }
    }

    private func fail(_ error: Error) {
        queue.async { self.capturing = false; self.detecting = true }
        DispatchQueue.main.async { self.delegate?.captureSessionManager(self, didFailWithError: error) }
    }
}
