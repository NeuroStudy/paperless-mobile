import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paperless_mobile_document_scanner/constants/constants.dart';
import 'package:paperless_mobile_document_scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile_document_scanner/models/debug_stage.dart';
import 'package:paperless_mobile_document_scanner/models/document_frame.dart';
import 'package:paperless_mobile_document_scanner/models/scan_result.dart';
import 'package:paperless_mobile_document_scanner/processing/detect_edges_from_file.dart';
import 'package:paperless_mobile_document_scanner/processing/image_edit.dart';
import 'package:paperless_mobile_document_scanner/processing/perspective_transform.dart';
import 'package:paperless_mobile_document_scanner/view/document_scanner_view.dart';
import 'package:paperless_mobile_document_scanner/view/image_edit_view.dart';
import 'package:paperless_mobile_document_scanner/view/widgets/debug_stage_switcher.dart';
import 'package:paperless_mobile_document_scanner/view/widgets/resolution_switcher.dart';
import 'package:paperless_mobile_document_scanner/view/widgets/scan_preview_list.dart';
import 'package:paperless_mobile_document_scanner/view/widgets/shutter_button.dart';
import 'package:path/path.dart' as p;

enum _ScanPhase { liveDetection, processing, imageEditing }

enum _SegmentedButtonOption { liveDetection, autoCapture }

const _shutterButtonSize = 72.0;
const _scanPreviewListHeight = 110.0;
const _actionButtonRowHeight = 56.0;

class PaperlessMobileDocumentScanner extends StatefulWidget {
  /// Called when the user finishes the scan session.
  /// Receives all accepted scans as a list of image files.
  final ValueChanged<List<File>> onCancelled;
  final ValueChanged<List<File>> onDone;

  /// Called when the user cancels the scan session.
  final bool liveDetectionInitiallyEnabled;

  /// Target capture resolution; devices may fall back if unsupported.
  /// Defaults to 1080p: 4K native JPEG captures on the S25 Ultra can contain
  /// corrupted chroma. Explicit resolution overrides remain available.
  final ResolutionPreset resolutionPreset;

  /// Configuration for auto-capture behaviour. When enabled, the scanner
  /// automatically takes a picture once the detected frame is stable.
  final AutoCaptureConfig autoCaptureConfig;

  const PaperlessMobileDocumentScanner({
    super.key,
    this.liveDetectionInitiallyEnabled = true,
    this.resolutionPreset = ResolutionPreset.veryHigh,
    this.autoCaptureConfig = const AutoCaptureConfig(
      enabled: true,
      preStableDelay: Duration(milliseconds: 300),
      stableDuration: Duration(milliseconds: 1000),
      minConsecutiveSimilarFrames: 4,
    ),
    required this.onCancelled,
    required this.onDone,
  });

  @override
  State<PaperlessMobileDocumentScanner> createState() =>
      _PaperlessMobileDocumentScannerState();
}

class _PaperlessMobileDocumentScannerState
    extends State<PaperlessMobileDocumentScanner> {
  late bool _liveDetectionEnabled;
  late AutoCaptureConfig _autoCaptureConfig;
  CameraController? _controller;
  DebugStage _debugStage = DebugStage.none;
  late ResolutionPreset _resolutionPreset;
  bool _isTorchActive = false;

  void _setController(CameraController? controller) {
    if (controller != _controller) {
      _controller = controller;
      _isTorchActive = false;
    }
  }

  _ScanPhase _phase = _ScanPhase.liveDetection;
  Future<List<CameraDescription>>? _availableCameras;
  DocumentFrame? _lastLiveFrame;
  Size? _lastLiveImageSize;

  /// Set when auto-capture fires, providing a high-confidence fallback frame.
  DocumentFrame? _autoCaptureFallbackFrame;
  Size? _autoCaptureFallbackImageSize;

  // --- State for a new capture (used until the user confirms or discards). ---
  Uint8List? _capturedImageBytes;
  Size? _capturedImageSize;
  DocumentFrame? _capturedFrame;
  String? _capturedFilePath;
  Uint8List? _initialCroppedBytes;

  // --- Re-edit state ---
  /// Index into [_scans] when re-editing an existing scan, or `null` for a
  /// fresh capture.
  int? _editingIndex;

  // Accumulated scan results.
  final List<ScanResult> _scans = [];

  // -----------------------------------------------------------------------
  // Capture flow
  // -----------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _resolutionPreset = widget.resolutionPreset;
    _liveDetectionEnabled = widget.liveDetectionInitiallyEnabled;
    _autoCaptureConfig = widget.autoCaptureConfig;
    _availableCameras = availableCameras();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  @override
  void dispose() {
    // Null out the reference to the CameraController so that any in-flight
    // async work (_onShutterPressed) will bail out on the mounted check
    // rather than using a disposed controller.
    _controller = null;
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  Future<void> _onShutterPressed() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      // Capture the image BEFORE switching phase, because changing phase
      // removes the camera view from the tree and disposes the controller.
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final xFile = await controller.takePicture();
      final capturedPath = xFile.path;
      final bytes = await File(capturedPath).readAsBytes();

      if (!mounted) return;
      _setController(null);
      setState(() => _phase = _ScanPhase.processing);

      // Get image dimensions.
      final decoded = await decodeImageFromList(bytes);
      final imageSize = Size(
        decoded.width.toDouble(),
        decoded.height.toDouble(),
      );
      decoded.dispose();

      // Detect edges on the captured (full-res) image using the accurate
      // detection config (higher resolution, finer parameters).
      var detectedFrame = await detectEdgesFromImageBytes(bytes);

      // If the user triggered this via auto-capture, the stable frame is the
      // frame they visually "agreed" to. If the accurate detection produced a
      // result that's drastically different (wrong document, background edge,
      // etc.), prefer the stable fallback.
      final fallback = _autoCaptureFallbackFrame;
      final fallbackSize = _autoCaptureFallbackImageSize;
      if (detectedFrame != null &&
          fallback != null &&
          fallbackSize != null &&
          !fallback.isPlausibleMatch(
            detectedFrame,
            thisImageSize: fallbackSize,
            candidateImageSize: imageSize,
          )) {
        debugPrint(
          'Accurate detection diverged from stable frame — using fallback.',
        );
        detectedFrame =
            null; // discard; fallback chain picks up the stable frame
      }

      // Fallback chain:
      //   1. Accurate detection on captured image (if plausible)
      //   2. Auto-capture stable frame (if auto-capture triggered this)
      //   3. Last live-detected frame
      //   4. Full image rectangle
      //
      // Fallback frames are in live-camera image coordinates, so they must
      // be scaled to the captured image's (full-res) coordinate space.
      DocumentFrame? frame = detectedFrame;
      if (frame == null) {
        final liveFallback = _autoCaptureFallbackFrame ?? _lastLiveFrame;
        final liveFallbackSize = _autoCaptureFallbackFrame != null
            ? _autoCaptureFallbackImageSize
            : _lastLiveImageSize;
        if (liveFallback != null && liveFallbackSize != null) {
          frame = liveFallback.mapToImage(
            from: liveFallbackSize,
            to: imageSize,
          );
        }
      }

      if (frame == null) {
        // No frame found at all — fallback to full image rectangle.
        _capturedFrame = DocumentFrame.fullImage(imageSize);
      } else {
        _capturedFrame = frame.clampedToImage(imageSize);
      }

      // Clear the one-shot auto-capture fallback.
      _autoCaptureFallbackFrame = null;
      _autoCaptureFallbackImageSize = null;

      _capturedImageBytes = bytes;
      _capturedImageSize = imageSize;
      _capturedFilePath = capturedPath;
      // Auto-crop immediately.
      final cropped = await perspectiveTransform(
        imageBytes: bytes,
        frame: _capturedFrame!,
      );

      if (mounted) {
        setState(() {
          _initialCroppedBytes = cropped;
          _editingIndex = null;
          _phase = _ScanPhase.imageEditing;
        });
      }
    } catch (e) {
      debugPrint('Capture/crop failed: $e');
      if (mounted) _returnToLiveDetection();
    }
  }

  Future<void> _onImageEditConfirmed(ImageEditResult result) async {
    // Generate a lightweight thumbnail for the preview list.
    final thumbnail = await generateThumbnail(result.editedBytes);

    if (_editingIndex != null) {
      // Re-edit: update the existing scan in place.
      final existing = _scans[_editingIndex!];
      await existing.outputFile.writeAsBytes(result.editedBytes, flush: true);
      existing.cropFrame = result.cropFrame;
      existing.quarterTurns = result.quarterTurns;
      existing.colorFilter = result.colorFilter;
      existing.bwThreshold = result.bwThreshold;
      existing.enhanced = result.enhanced;
      existing.reduceShadows = result.reduceShadows;
      existing.thumbnailBytes = thumbnail;
    } else {
      // New scan: write the output file and create a ScanResult.
      final scanFile = await _writeScanFile(result.editedBytes);
      _scans.add(
        ScanResult(
          originalFile: File(_capturedFilePath!),
          originalImageSize: _capturedImageSize!,
          cropFrame: result.cropFrame,
          quarterTurns: result.quarterTurns,
          colorFilter: result.colorFilter,
          bwThreshold: result.bwThreshold,
          enhanced: result.enhanced,
          reduceShadows: result.reduceShadows,
          thumbnailBytes: thumbnail,
          outputFile: scanFile,
        ),
      );
    }

    _editingIndex = null;
    _returnToLiveDetection();
  }

  void _onImageEditCancelled() {
    if (_editingIndex == null) {
      // New capture discarded — delete the original capture file.
      _deleteOriginalCapture();
    }
    _editingIndex = null;
    _returnToLiveDetection();
  }

  void _onScanTapped(int index) {
    _setController(null);
    setState(() {
      _editingIndex = index;
      _phase = _ScanPhase.imageEditing;
    });
  }

  void _onScanDeleted(int index) {
    final scan = _scans.removeAt(index);
    scan.outputFile.delete().catchError((_) => scan.outputFile);
    scan.originalFile.delete().catchError((_) => scan.originalFile);
    setState(() {});
  }

  void _onScanReordered(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final scan = _scans.removeAt(oldIndex);
      _scans.insert(newIndex, scan);
    });
  }

  void _returnToLiveDetection() {
    setState(() {
      _phase = _ScanPhase.liveDetection;
      _capturedImageBytes = null;
      _capturedImageSize = null;
      _capturedFrame = null;
      _initialCroppedBytes = null;
      _capturedFilePath = null;
    });
  }

  void _deleteOriginalCapture() {
    if (_capturedFilePath != null) {
      File(_capturedFilePath!).delete().catchError((_) => File(''));
      _capturedFilePath = null;
    }
  }

  /// Writes [bytes] to a new file in the system temp directory.
  Future<File> _writeScanFile(Uint8List bytes) async {
    final dir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'scan_$timestamp.png'));
    return file.writeAsBytes(bytes, flush: true);
  }

  void _onFrameChanged(DocumentFrame? frame, Size? imageSize) {
    // Keep a reference to the last detected frame for the capture fallback.
    _lastLiveFrame = frame;
    _lastLiveImageSize = imageSize;
  }

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _ScanPhase.processing => const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      ),
      _ScanPhase.imageEditing => _buildImageEditing(),
      _ScanPhase.liveDetection => _buildLiveDetection(),
    };
  }

  Widget _buildImageEditing() {
    final scan = _editingIndex != null ? _scans[_editingIndex!] : null;

    if (scan != null) {
      // Re-edit: load from file on demand.
      return ImageEditView(
        originalImageFile: scan.originalFile,
        originalImageSize: scan.originalImageSize,
        initialCropFrame: scan.cropFrame,
        initialQuarterTurns: scan.quarterTurns,
        initialColorFilter: scan.colorFilter,
        initialBwThreshold: scan.bwThreshold,
        initialEnhanced: scan.enhanced,
        initialReduceShadows: scan.reduceShadows,
        onConfirmed: _onImageEditConfirmed,
        onCancelled: _onImageEditCancelled,
        isNewCapture: false,
      );
    }

    // New capture: bytes already in memory.
    return ImageEditView(
      originalImageBytes: _capturedImageBytes!,
      originalImageSize: _capturedImageSize!,
      initialCropFrame: _capturedFrame!,
      initialCroppedBytes: _initialCroppedBytes!,
      animateEntry: true,
      onConfirmed: _onImageEditConfirmed,
      onCancelled: _onImageEditCancelled,
      isNewCapture: true,
    );
  }

  Widget _buildLiveDetection() {
    return FutureBuilder(
      future: _availableCameras,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          if (error is CameraException) {
            final message = mapCameraErrorCode(error.code);
            return Center(child: Text('$message: ${error.description}'));
          }
          return const Center(child: Text('Error loading cameras'));
        }
        final cameras = snapshot.data!;
        if (cameras.isEmpty) {
          return const Center(child: Text('No cameras found'));
        }
        final camera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        const bottomBarVerticalPadding = 8.0;
        final bottomBarHeight =
            _shutterButtonSize +
            _actionButtonRowHeight +
            (_scans.isNotEmpty ? _scanPreviewListHeight : 0) +
            2 * bottomBarVerticalPadding;
        return Scaffold(
          bottomNavigationBar: BottomAppBar(
            // The rows provide vertical padding; BottomAppBar adds the safe area.
            padding: const EdgeInsets.symmetric(horizontal: 16),
            height: bottomBarHeight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Shutter + torch row.
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: bottomBarVerticalPadding,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      RepaintBoundary(
                        child: ShutterButton(
                          onPressed: _onShutterPressed,
                          size: _shutterButtonSize,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: RepaintBoundary(
                          child: SegmentedButton<_SegmentedButtonOption>(
                            multiSelectionEnabled: true,
                            emptySelectionAllowed: true,
                            onSelectionChanged: (newSelection) {
                              setState(() {
                                _liveDetectionEnabled = newSelection.contains(
                                  _SegmentedButtonOption.liveDetection,
                                );
                                _autoCaptureConfig = widget.autoCaptureConfig
                                    .copyWith(
                                      enabled: newSelection.contains(
                                        _SegmentedButtonOption.autoCapture,
                                      ),
                                    );
                              });
                            },
                            showSelectedIcon: false,
                            segments: [
                              ButtonSegment(
                                value: _SegmentedButtonOption.liveDetection,
                                icon: Icon(Icons.document_scanner),
                                tooltip: 'Live Detection',
                              ),
                              ButtonSegment(
                                value: _SegmentedButtonOption.autoCapture,
                                icon: Icon(Icons.motion_photos_auto),
                                enabled: _liveDetectionEnabled,

                                tooltip: 'Auto Capture',
                              ),
                            ],
                            selected: {
                              if (_liveDetectionEnabled)
                                _SegmentedButtonOption.liveDetection,
                              if (_autoCaptureConfig.enabled &&
                                  _liveDetectionEnabled)
                                _SegmentedButtonOption.autoCapture,
                            },
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: RepaintBoundary(child: _buildTorchButton()),
                        ),
                      ),
                    ],
                  ),
                ),
                // Cancel / Done buttons.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    height: _actionButtonRowHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () => widget.onCancelled(
                            _scans.map((s) => s.outputFile).toList(),
                          ),
                          child: Text(
                            MaterialLocalizations.of(context).cancelButtonLabel,
                          ),
                        ),
                        if (_scans.isNotEmpty)
                          FilledButton.icon(
                            onPressed: () {
                              widget.onDone(
                                _scans.map((s) => s.outputFile).toList(),
                              );
                            },
                            icon: const Icon(Icons.done_all),
                            label: Text('Done (${_scans.length})'),
                          ),
                      ],
                    ),
                  ),
                ),
                // Scan preview list.
                if (_scans.isNotEmpty)
                  ScanPreviewList(
                    scans: _scans,
                    onDelete: _onScanDeleted,
                    onTap: _onScanTapped,
                    onReorder: _onScanReordered,
                    height: _scanPreviewListHeight,
                  ),
              ],
            ),
          ),
          body: Stack(
            children: [
              // Camera preview with live edge detection.
              DocumentScannerView(
                key: ValueKey(_resolutionPreset),
                onControllerInitialized: _setController,
                camera: camera,
                debugStage: kDebugMode ? _debugStage : DebugStage.none,
                resolutionPreset: _resolutionPreset,
                onFrameChanged: _onFrameChanged,
                liveEdgeDetectionEnabled: _liveDetectionEnabled,
                autoCaptureConfig: _autoCaptureConfig,
                onAutoCaptureTriggered: (stableFrame) {
                  _autoCaptureFallbackFrame = stableFrame;
                  _autoCaptureFallbackImageSize = _lastLiveImageSize;
                  _onShutterPressed();
                },
              ),
              if (kDebugMode) _buildDebugControls(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDebugControls() {
    return Positioned(
      top: 8,
      right: 8,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            DebugStageSwitcher(
              value: _debugStage,
              onChanged: (stage) => setState(() => _debugStage = stage),
            ),
            const SizedBox(height: 8),
            ResolutionSwitcher(
              value: _resolutionPreset,
              onChanged: (preset) => setState(() => _resolutionPreset = preset),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTorchButton() {
    return IconButton.filledTonal(
      onPressed: () async {
        final controller = _controller;
        if (controller == null || !controller.value.isInitialized) return;
        final wantTorch = !_isTorchActive;
        await controller.setFlashMode(
          wantTorch ? FlashMode.torch : FlashMode.off,
        );
        setState(() => _isTorchActive = wantTorch);
      },
      icon: Icon(
        _isTorchActive ? Icons.flashlight_off : Icons.flashlight_on,
        size: 32,
      ),
    );
  }
}
