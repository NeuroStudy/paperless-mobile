import Flutter
import UIKit
import WeScan

public final class SwiftEdgeDetectionPlugin: NSObject, FlutterPlugin, ImageScannerControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private var pending: FlutterResult?
    private var destination: String?
    private weak var presenter: UIViewController?
    private var allowGallery = true
    private var saving = false
    private let queue = DispatchQueue(label: "paperless.scanner.save", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "edge_detection", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SwiftEdgeDetectionPlugin(), channel: channel)
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "edge_detect" || call.method == "edge_detect_gallery" else { result(FlutterMethodNotImplemented); return }
        guard pending == nil else { result(FlutterError(code: "already_active", message: "The document scanner is already open.", details: nil)); return }
        guard let args = call.arguments as? [String: Any], let path = args["save_to"] as? String, !path.isEmpty else {
            result(FlutterError(code: "invalid_path", message: "A scan destination is required.", details: nil)); return
        }
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController
            ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            result(FlutterError(code: "no_activity", message: "A foreground window is required.", details: nil)); return
        }
        var host = root
        while let top = host.presentedViewController { host = top }
        presenter = host; pending = result; destination = path; allowGallery = args["can_use_gallery"] as? Bool ?? true
        if call.method == "edge_detect_gallery" {
            let picker = UIImagePickerController(); picker.delegate = self; picker.sourceType = .photoLibrary
            picker.isModalInPresentation = true; host.present(picker, animated: true)
        } else { presentScanner(image: nil) }
    }
    private func presentScanner(image: UIImage?) {
        let scanner = ImageScannerController(image: image, delegate: self)
        scanner.canUseGallery = allowGallery; scanner.isModalInPresentation = true
        scanner.overrideUserInterfaceStyle = .dark; scanner.modalPresentationStyle = .fullScreen
        presenter?.present(scanner, animated: true)
    }
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) { self.complete(false) } }
    public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true) { if let image = image { self.presentScanner(image: image) } else { self.complete(false) } }
    }
    public func imageScannerControllerDidCancel(_ scanner: ImageScannerController) { scanner.dismiss(animated: true) { self.complete(false) } }
    public func imageScannerController(_ scanner: ImageScannerController, didFailWithError error: Error) {
        scanner.dismiss(animated: true) { self.complete(FlutterError(code: "scan_failed", message: error.localizedDescription, details: nil)) }
    }
    public func imageScannerController(_ scanner: ImageScannerController, didFinishScanningWithResults results: ImageScannerResults) {
        guard !saving, let destination = destination else { return }
        saving = true; scanner.view.isUserInteractionEnabled = false
        queue.async {
            do {
                guard let data = results.croppedScan.image.jpegData(compressionQuality: 0.95), !data.isEmpty else {
                    throw NSError(domain: "paperless.scanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode the scan."])
                }
                try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
                DispatchQueue.main.async { scanner.dismiss(animated: true) { self.complete(true) } }
            } catch {
                DispatchQueue.main.async {
                    self.saving = false; scanner.view.isUserInteractionEnabled = true
                    let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default)); scanner.present(alert, animated: true)
                }
            }
        }
    }
    private func complete(_ value: Any) {
        let callback = pending; pending = nil; destination = nil; saving = false; presenter = nil; callback?(value)
    }
}
