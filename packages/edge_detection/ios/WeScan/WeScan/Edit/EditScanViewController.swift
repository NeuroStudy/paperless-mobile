import UIKit
import AVFoundation

final class EditScanViewController: UIViewController {
    private var image: UIImage
    private var previewSource: UIImage?
    private var quad = ScanProcessing.fullImage
    private var draft = ScanProcessing.fullImage
    private var turns = 0
    private var filter = ScanFilter.enhanced
    private var reduceShadows = true
    // The serial render queue owns the cached profile.
    private var enhancement: ScanEnhancementProfile?
    private var enhancementCrop: [CGPoint]?
    private var pendingPreview: DispatchWorkItem?
    private var editing = false
    private var busy = true
    private var generation = 0
    private var dragActive = false
    private let queue = DispatchQueue(label: "paperless.scanner.editor", qos: .userInitiated)
    private let container = UIView()
    private let imageView = UIImageView()
    private let quadView = QuadrilateralView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var zoom: ZoomGestureController?
    private let filters = UISegmentedControl(items: ScanFilter.allCases.map { $0.title })
    private let cropButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let retakeButton = UIButton(type: .system)
    private let shadowSwitch = UISwitch()
    private let shadowRow = UIStackView()
    private var initialQuad: Quadrilateral?

    init(image: UIImage, quad: Quadrilateral?, rotateImage: Bool = true) {
        self.image = image; self.initialQuad = quad
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = scanText("paperless.edit", "Edit scan")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: scanText("paperless.save", "Save"), style: .done, target: self, action: #selector(save))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: scanText("paperless.cancel", "Cancel"), style: .plain, target: self, action: #selector(cancel))
        imageView.contentMode = .scaleAspectFit; imageView.clipsToBounds = true
        quadView.editable = true; quadView.isHidden = true
        container.addSubview(imageView); container.addSubview(quadView); container.addSubview(spinner)
        filters.selectedSegmentIndex = filter.rawValue
        filters.addTarget(self, action: #selector(selectFilter), for: .valueChanged)
        filters.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 11)], for: .normal)
        cropButton.addTarget(self, action: #selector(crop), for: .touchUpInside)
        rotateButton.setTitle(scanText("paperless.rotate", "Rotate"), for: .normal)
        rotateButton.addTarget(self, action: #selector(rotate), for: .touchUpInside)
        retakeButton.addTarget(self, action: #selector(retake), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [retakeButton, cropButton, rotateButton])
        actions.axis = .horizontal; actions.distribution = .fillEqually
        let shadowLabel = UILabel()
        shadowLabel.text = scanText("paperless.reduceShadows", "Reduce shadows"); shadowLabel.textColor = .white
        shadowLabel.font = .preferredFont(forTextStyle: .body); shadowLabel.adjustsFontForContentSizeCategory = true
        shadowSwitch.isOn = reduceShadows; shadowSwitch.accessibilityLabel = shadowLabel.text
        shadowSwitch.addTarget(self, action: #selector(toggleShadows), for: .valueChanged)
        shadowRow.addArrangedSubview(shadowLabel); shadowRow.addArrangedSubview(shadowSwitch)
        shadowRow.axis = .horizontal; shadowRow.alignment = .center; shadowRow.spacing = 12
        let stack = UIStackView(arrangedSubviews: [container, filters, shadowRow, actions]); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            actions.heightAnchor.constraint(equalToConstant: 48), filters.heightAnchor.constraint(equalToConstant: 40)])
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        gesture.minimumPressDuration = 0; quadView.addGestureRecognizer(gesture)
        updateControls()
        let source = image; let detected = initialQuad
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let upright = ScanProcessing.upright(source),
                  let small = ScanProcessing.upright(upright, maxEdge: 1200), let cgImage = upright.cgImage else {
                DispatchQueue.main.async { self.busy = false; self.updateControls(); self.showError() }
                return
            }
            let finish: (Quadrilateral?) -> Void = { result in
                DispatchQueue.main.async {
                    self.image = upright; self.previewSource = small
                    self.quad = result.map { $0.applying(CGAffineTransform(scaleX: 1 / upright.size.width, y: 1 / upright.size.height)) } ?? ScanProcessing.fullImage
                    if !self.quad.scanIsValid { self.quad = ScanProcessing.fullImage }
                    self.zoom = ZoomGestureController(image: upright, quadView: self.quadView)
                    self.renderPreview()
                }
            }
            if let detected = detected { finish(detected) }
            else { VisionRectangleDetector.rectangle(forImage: CIImage(cgImage: cgImage)) { finish($0?.toCartesian(withHeight: upright.size.height)) } }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        imageView.frame = container.bounds
        quadView.frame = AVMakeRect(aspectRatio: image.size, insideRect: container.bounds)
        spinner.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        if editing { drawDraft() }
    }
    private func drawDraft() { quadView.drawQuadrilateral(quad: draft.applying(CGAffineTransform(scaleX: quadView.bounds.width, y: quadView.bounds.height)), animated: false) }

    private func renderPreview() {
        guard let source = previewSource else { return }
        generation += 1
        pendingPreview?.cancel()
        let version = generation, crop = quad, rotation = turns, selected = filter, shadows = reduceShadows, full = image
        busy = true; updateControls()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let output = autoreleasepool { () -> UIImage? in
                let profile = selected == .enhanced && shadows ? self.profileFor(full, crop: crop) : nil
                return ScanProcessing.render(source, quad: crop, turns: rotation, filter: selected, maxEdge: 1200, reduceShadows: shadows, profile: profile)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == version else { return }
                self.busy = false
                if let output = output { self.imageView.image = output } else { self.showError() }
                self.updateControls()
            }
        }
        pendingPreview = work; queue.async(execute: work)
    }
    private func profileFor(_ source: UIImage, crop: Quadrilateral) -> ScanEnhancementProfile {
        if enhancement == nil || enhancementCrop != crop.scanPoints {
            enhancement = ScanProcessing.prepareEnhancement(source, quad: crop); enhancementCrop = crop.scanPoints
        }
        return enhancement!
    }
    @objc private func toggleShadows() { reduceShadows = shadowSwitch.isOn; renderPreview() }
    @objc private func selectFilter() { filter = ScanFilter(rawValue: filters.selectedSegmentIndex) ?? .enhanced; if !editing { renderPreview() } }
    @objc private func rotate() { turns = (turns + 1) % 4; renderPreview() }
    @objc private func crop() {
        if editing { quad = draft; endCrop(); renderPreview() }
        else { editing = true; draft = quad; imageView.image = previewSource; quadView.isHidden = false; drawDraft(); updateControls() }
    }
    private func endCrop() { editing = false; quadView.isHidden = true; quadView.resetHighlightedCornerViews(); updateControls() }
    @objc private func retake() {
        if editing { endCrop(); renderPreview() }
        else if let navigation = navigationController, navigation.viewControllers.count > 1 { navigation.popViewController(animated: true) }
        else { cancel() }
    }
    @objc private func cancel() {
        if editing { endCrop(); renderPreview(); return }
        guard let scanner = navigationController as? ImageScannerController else { return }
        scanner.imageScannerDelegate?.imageScannerControllerDidCancel(scanner)
    }
    @objc private func drag(_ gesture: UILongPressGestureRecognizer) {
        guard editing else { return }
        if gesture.state == .began {
            let location = gesture.location(in: quadView)
            let distance = (quadView.quad?.scanPoints ?? []).map { hypot($0.x - location.x, $0.y - location.y) }.min() ?? 1000
            dragActive = distance <= 44
        }
        guard dragActive else { return }
        zoom?.handle(pan: gesture)
        if let drawn = quadView.quad, quadView.bounds.width > 0, quadView.bounds.height > 0 {
            let updated = drawn.applying(CGAffineTransform(scaleX: 1 / quadView.bounds.width, y: 1 / quadView.bounds.height))
            if updated.scanIsValid { draft = updated }
        }
        if gesture.state == .ended || gesture.state == .cancelled { dragActive = false }
    }
    private func updateControls() {
        cropButton.setTitle(scanText(editing ? "paperless.apply" : "paperless.crop", editing ? "Apply" : "Crop"), for: .normal)
        retakeButton.setTitle(scanText(editing ? "paperless.cancel" : "paperless.retake", editing ? "Cancel" : "Retake"), for: .normal)
        cropButton.isEnabled = !busy; rotateButton.isEnabled = !busy && !editing
        navigationItem.rightBarButtonItem?.isEnabled = !busy && !editing
        filters.isEnabled = previewSource != nil && !busy
        shadowRow.isHidden = filter != .enhanced || editing
        shadowSwitch.isEnabled = previewSource != nil && !busy
        busy ? spinner.startAnimating() : spinner.stopAnimating()
    }
    @objc private func save() {
        guard !busy && !editing else { return }
        busy = true; updateControls()
        let source = image, crop = quad, rotation = turns, selected = filter, shadows = reduceShadows
        queue.async { [weak self] in
            guard let self = self else { return }
            let output = autoreleasepool { () -> UIImage? in
                let profile = selected == .enhanced && shadows ? self.profileFor(source, crop: crop) : nil
                return ScanProcessing.render(source, quad: crop, turns: rotation, filter: selected, maxEdge: 4096, reduceShadows: shadows, profile: profile)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let scanner = self.navigationController as? ImageScannerController else { return }
                self.busy = false; self.updateControls()
                guard let output = output else { self.showError(); return }
                let pixelQuad = crop.applying(CGAffineTransform(scaleX: source.size.width, y: source.size.height))
                let results = ImageScannerResults(detectedRectangle: pixelQuad, originalScan: ImageScannerScan(image: source), croppedScan: ImageScannerScan(image: output), enhancedScan: nil)
                scanner.imageScannerDelegate?.imageScannerController(scanner, didFinishScanningWithResults: results)
            }
        }
    }
    private func showError() {
        let alert = UIAlertController(title: nil, message: scanText("paperless.error", "Could not process the scan. Please try again."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
