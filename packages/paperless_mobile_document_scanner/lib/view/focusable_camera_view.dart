import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class FocusableCameraView extends StatefulWidget {
  final CameraDescription camera;
  final ResolutionPreset resolutionPreset;
  final ValueChanged<CameraController> onControllerInitialized;
  const FocusableCameraView({
    super.key,
    required this.camera,
    this.resolutionPreset = ResolutionPreset.medium,
    required this.onControllerInitialized,
  });

  @override
  State<FocusableCameraView> createState() => _FocusableCameraViewState();
}

const _focusIndicatorSize = 72.0;

class _FocusableCameraViewState extends State<FocusableCameraView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _controller;
  Future<void>? _controllerInitialization;
  Future<void> _cameraShutdown = Future<void>.value();
  bool _cameraActive = true;
  bool _disposed = false;

  late final AnimationController _focusAnimController;
  Offset? _focusPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusAnimController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 400),
        )..addStatusListener((status) {
          if (!_disposed && mounted && status == AnimationStatus.completed) {
            setState(() => _focusPosition = null);
          }
        });
    _initializeCameraController();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _releaseCameraController();
    _focusAnimController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.inactive) {
      _cameraActive = false;
      _releaseCameraController();
      setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      _cameraActive = true;
      _initializeCameraController();
    }
  }

  bool _isCurrentController(CameraController controller) =>
      !_disposed &&
      mounted &&
      _cameraActive &&
      identical(_controller, controller);

  void _onCameraChanged() {
    final controller = _controller;
    if (controller == null || !_isCurrentController(controller)) return;
    if (controller.value.hasError) {
      debugPrint('Camera error ${controller.value.errorDescription}');
    }
    setState(() {});
  }

  void _releaseCameraController() {
    final controller = _controller;
    if (controller == null) return;
    // stopImageStream changes CameraValue synchronously. Detach before calling
    // it: mounted is still true inside dispose, while the tree is being torn down.
    controller.removeListener(_onCameraChanged);
    _controller = null;
    final initialization = _controllerInitialization;
    _controllerInitialization = null;
    _cameraShutdown = _shutdownCamera(controller, initialization);
    unawaited(_cameraShutdown);
  }

  Future<void> _shutdownCamera(
    CameraController controller,
    Future<void>? initialization,
  ) async {
    try {
      // The plugin's flash setter also notifies after its platform await.
      // Let initialization finish before disposing its notifier/native camera.
      await initialization;
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } on CameraException catch (e) {
      debugPrint('Camera stream shutdown failed: $e');
    } finally {
      try {
        await controller.dispose();
      } on CameraException catch (e) {
        debugPrint('Camera shutdown failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: cameraController.value.previewSize!.height,
              height: cameraController.value.previewSize!.width,
              child: CameraPreview(
                cameraController,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (TapDownDetails details) =>
                          onViewFinderTap(details, constraints),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (_focusPosition != null)
          AnimatedBuilder(
            animation: _focusAnimController,
            builder: (context, child) {
              final t = _focusAnimController.value;
              // Scale: 1.5 → 1.0 over first 30%.
              final scaleT = (t / 0.3).clamp(0.0, 1.0);
              final scale = 1.5 - 0.5 * Curves.easeOut.transform(scaleT);
              // Opacity: 1.0 for first 70%, then fade to 0.
              final opacityT = ((t - 0.7) / 0.3).clamp(0.0, 1.0);
              final opacity = 1.0 - Curves.easeIn.transform(opacityT);
              return Positioned(
                left: _focusPosition!.dx - _focusIndicatorSize / 2,
                top: _focusPosition!.dy - _focusIndicatorSize / 2,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.scale(scale: scale, child: child),
                  ),
                ),
              );
            },
            child: SizedBox(
              width: _focusIndicatorSize,
              height: _focusIndicatorSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _initializeCameraController() async {
    // A resume must wait for the previous camera to release its native resources.
    await _cameraShutdown;
    if (_disposed || !mounted || !_cameraActive || _controller != null) return;
    final cameraController = CameraController(
      widget.camera,
      widget.resolutionPreset,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    _controller = cameraController;
    cameraController.addListener(_onCameraChanged);
    return _controllerInitialization = _configureCameraController(
      cameraController,
    );
  }

  Future<void> _configureCameraController(
    CameraController cameraController,
  ) async {
    try {
      await cameraController.initialize();
      if (!_isCurrentController(cameraController)) return;
      await cameraController.setFlashMode(FlashMode.off);
      if (!_isCurrentController(cameraController)) return;
      widget.onControllerInitialized(cameraController);
    } on CameraException catch (e) {
      switch (e.code) {
        case 'CameraAccessDenied':
          debugPrint('You have denied camera access.');
          break;
        case 'CameraAccessDeniedWithoutPrompt':
          // iOS only
          debugPrint('Please go to Settings app to enable camera access.');
          break;
        case 'CameraAccessRestricted':
          // iOS only
          debugPrint('Camera access is restricted.');
          break;
        case 'AudioAccessDenied':
          debugPrint('You have denied audio access.');
          break;
        case 'AudioAccessDeniedWithoutPrompt':
          // iOS only
          debugPrint('Please go to Settings app to enable audio access.');
          break;
        case 'AudioAccessRestricted':
          // iOS only
          debugPrint('Audio access is restricted.');
          break;
        default:
          debugPrint('Unknown camera error: ${e.code}');
          break;
      }
    }

    if (_isCurrentController(cameraController)) {
      setState(() {});
    }
  }

  void onViewFinderTap(TapDownDetails details, BoxConstraints constraints) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    final Offset offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    cameraController.setExposurePoint(offset);
    cameraController.setFocusPoint(offset);

    // Show focus indicator at the tap position in screen coordinates.
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box != null) {
      setState(() {
        _focusPosition = box.globalToLocal(details.globalPosition);
      });
      _focusAnimController.forward(from: 0.0);
    }
  }
}
