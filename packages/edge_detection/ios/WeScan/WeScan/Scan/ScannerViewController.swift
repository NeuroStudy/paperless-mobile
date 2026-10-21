import AVFoundation
import UIKit

public final class ScannerViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let viewport = UIView()
    private let preview = AVCaptureVideoPreviewLayer()
    private let dots = CAShapeLayer()
    private let shutter = ShutterButton()
    private let gallery = UIButton(type: .system)
    private let flash = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private var manager: CaptureSessionManager?
    private var flashEnabled = false
    private var latestQuad: Quadrilateral?
    private var latestSize = CGSize.zero

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        viewport.clipsToBounds = true; viewport.layer.addSublayer(preview)
        dots.fillColor = UIColor.white.cgColor; dots.strokeColor = UIColor.darkGray.cgColor; dots.lineWidth = 1
        viewport.layer.addSublayer(dots)
        shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)
        gallery.setTitle(scanText("paperless.gallery", "Gallery"), for: .normal)
        gallery.addTarget(self, action: #selector(importImage), for: .touchUpInside)
        flash.setTitle(scanText("paperless.flash", "Flash"), for: .normal)
        flash.addTarget(self, action: #selector(toggleFlash), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [flash, shutter, gallery])
        controls.axis = .horizontal; controls.distribution = .equalCentering; controls.alignment = .center
        [viewport, controls, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        let ratio = viewport.widthAnchor.constraint(equalTo: viewport.heightAnchor, multiplier: 0.75)
        let width = viewport.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32); width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            ratio, width,
            viewport.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            viewport.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -48),
            viewport.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            viewport.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            viewport.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            viewport.bottomAnchor.constraint(lessThanOrEqualTo: controls.topAnchor, constant: -16),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            controls.heightAnchor.constraint(equalToConstant: 65),
            shutter.widthAnchor.constraint(equalToConstant: 65), shutter.heightAnchor.constraint(equalToConstant: 65),
            spinner.centerXAnchor.constraint(equalTo: viewport.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: viewport.centerYAnchor)])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Auto", style: .plain, target: self, action: #selector(toggleAuto))
        manager = CaptureSessionManager(videoPreviewLayer: preview, delegate: self)
        let focus = UITapGestureRecognizer(target: self, action: #selector(focus(_:))); viewport.addGestureRecognizer(focus)
        if manager == nil { captureSessionManagerFailed() }
        updateAutoTitle()
    }
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        CaptureSession.current.isEditing = false
        gallery.isHidden = !((navigationController as? ImageScannerController)?.canUseGallery ?? true)
        flash.isHidden = !UIImagePickerController.isFlashAvailable(for: .rear)
        latestQuad = nil; dots.path = nil; shutter.isEnabled = true; spinner.stopAnimating(); manager?.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }
    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        manager?.stop(); UIApplication.shared.isIdleTimerDisabled = false
        if flashEnabled { _ = CaptureSession.current.toggleFlash(); flashEnabled = false }
    }
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview.frame = viewport.bounds; dots.frame = viewport.bounds; drawDots()
    }
    @objc private func capture() { shutter.isEnabled = false; manager?.capturePhoto() }
    @objc private func cancel() {
        guard let scanner = navigationController as? ImageScannerController else { return }
        scanner.imageScannerDelegate?.imageScannerControllerDidCancel(scanner)
    }
    @objc private func toggleFlash() {
        switch CaptureSession.current.toggleFlash() { case .on: flashEnabled = true; default: flashEnabled = false }
        flash.tintColor = flashEnabled ? .systemYellow : .systemBlue
    }
    @objc private func toggleAuto() { CaptureSession.current.isAutoScanEnabled.toggle(); updateAutoTitle() }
    private func updateAutoTitle() {
        navigationItem.rightBarButtonItem?.title = scanText(CaptureSession.current.isAutoScanEnabled ? "paperless.auto" : "paperless.manual", CaptureSession.current.isAutoScanEnabled ? "Auto" : "Manual")
    }
    @objc private func focus(_ gesture: UITapGestureRecognizer) {
        let point = preview.captureDevicePointConverted(fromLayerPoint: gesture.location(in: viewport))
        try? CaptureSession.current.setFocusPointToTapPoint(point)
    }
    @objc private func importImage() {
        let picker = UIImagePickerController(); picker.sourceType = .photoLibrary; picker.delegate = self; present(picker, animated: true)
    }
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { if let image = image { self.navigationController?.pushViewController(EditScanViewController(image: image, quad: nil, rotateImage: false), animated: true) } }
    }
    private func drawDots() {
        guard let quad = latestQuad, latestSize.width > 0, latestSize.height > 0 else { dots.path = nil; return }
        // Camera buffer is landscape. Rotate into the portrait preview, then fit it.
        let portraitSize = CGSize(width: latestSize.height, height: latestSize.width)
        let frame = AVMakeRect(aspectRatio: portraitSize, insideRect: viewport.bounds)
        let scale = frame.width / portraitSize.width
        let path = UIBezierPath()
        quad.scanPoints.forEach { point in
            let displayed = CGPoint(x: frame.minX + (latestSize.height - point.y) * scale,
                                    y: frame.minY + point.x * scale)
            path.append(UIBezierPath(ovalIn: CGRect(x: displayed.x - 4, y: displayed.y - 4, width: 8, height: 8)))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); dots.path = path.cgPath; CATransaction.commit()
    }
    private func captureSessionManagerFailed() {
        DispatchQueue.main.async {
            guard let scanner = self.navigationController as? ImageScannerController else { return }
            scanner.imageScannerDelegate?.imageScannerController(scanner, didFailWithError: ImageScannerControllerError.inputDevice)
        }
    }
}

extension ScannerViewController: RectangleDetectionDelegateProtocol {
    func didStartCapturingPicture(for captureSessionManager: CaptureSessionManager) { shutter.isEnabled = false; spinner.startAnimating() }
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didDetectQuad quad: Quadrilateral?, _ imageSize: CGSize) {
        latestQuad = quad; latestSize = imageSize; drawDots()
    }
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didCapturePicture picture: UIImage, withQuad quad: Quadrilateral?) {
        spinner.stopAnimating(); shutter.isEnabled = true
        navigationController?.pushViewController(EditScanViewController(image: picture, quad: quad, rotateImage: false), animated: false)
    }
    func captureSessionManager(_ captureSessionManager: CaptureSessionManager, didFailWithError error: Error) {
        spinner.stopAnimating(); shutter.isEnabled = true
        guard let scanner = navigationController as? ImageScannerController else { return }
        scanner.imageScannerDelegate?.imageScannerController(scanner, didFailWithError: error)
    }
}
