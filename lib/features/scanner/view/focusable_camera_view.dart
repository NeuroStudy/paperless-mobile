import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class FocusableCameraView extends StatefulWidget {
  final CameraDescription camera;
  final ResolutionPreset resolutionPreset;
  final Future<void> Function(CameraController?) onControllerChanged;
  @visibleForTesting
  final CameraController Function()? controllerFactory;
  const FocusableCameraView({
    super.key,
    required this.camera,
    this.resolutionPreset = ResolutionPreset.medium,
    required this.onControllerChanged,
    this.controllerFactory,
  });

  @override
  State<FocusableCameraView> createState() => FocusableCameraViewState();
}

const _focusIndicatorSize = 72.0;

class FocusableCameraViewState extends State<FocusableCameraView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _controller;
  Future<void> _transition = Future.value();
  int _generation = 0;
  bool _disposing = false;
  bool _active = true;

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
          if (status == AnimationStatus.completed) {
            setState(() => _focusPosition = null);
          }
        });
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _active = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    unawaited(restartCamera());
  }

  @override
  void didUpdateWidget(covariant FocusableCameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.camera != widget.camera ||
        oldWidget.resolutionPreset != widget.resolutionPreset) {
      unawaited(restartCamera());
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    _focusAnimController.dispose();
    unawaited(restartCamera());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_active == active) return;
    _active = active;
    // Also invalidate initialization that has not completed yet.
    unawaited(restartCamera());
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

  /// Stream shutdown, release and reinitialization share one transition queue.
  Future<void> restartCamera() {
    final generation = ++_generation;
    final previous = _controller;
    _controller = null;
    previous?.removeListener(_onCameraChanged);
    if (mounted && !_disposing) setState(() {});
    // Invalidate recognition immediately, even if initialization or a previous
    // stream transition is still pending in the camera queue.
    final invalidated = previous == null
        ? Future<void>.value()
        : widget.onControllerChanged(null);
    final operation = _transition.then((_) async {
      await invalidated;
      if (previous != null) await _release(previous);
      if (!mounted || _disposing || !_active || generation != _generation) {
        return;
      }

      final camera =
          widget.controllerFactory?.call() ??
          CameraController(
            widget.camera,
            widget.resolutionPreset,
            enableAudio: false,
            fps: 30,
            imageFormatGroup: Platform.isAndroid
                ? ImageFormatGroup.nv21
                : ImageFormatGroup.bgra8888,
          );
      _controller = camera;
      camera.addListener(_onCameraChanged);
      try {
        await camera.initialize();
        if (!_isCurrent(camera, generation)) return;
        try {
          await camera
              .setFlashMode(FlashMode.off)
              .timeout(const Duration(seconds: 2));
        } catch (error) {
          // Optional flash setup must not prevent recognition from starting.
          debugPrint('Camera flash setup failed: $error');
        }
        if (!_isCurrent(camera, generation)) return;
        await widget.onControllerChanged(camera);
        if (_isCurrent(camera, generation)) setState(() {});
      } catch (error) {
        if (!_isCurrent(camera, generation)) return;
        debugPrint('Camera initialization failed: $error');
        _controller = null;
        camera.removeListener(_onCameraChanged);
        await widget.onControllerChanged(null);
        await _release(camera);
      }
    });
    _transition = operation.catchError((Object error) {
      debugPrint('Camera lifecycle transition failed: $error');
    });
    return _transition;
  }

  bool _isCurrent(CameraController camera, int generation) =>
      mounted &&
      !_disposing &&
      _active &&
      generation == _generation &&
      identical(_controller, camera);

  Future<void> _release(CameraController camera) async {
    try {
      if (camera.value.isStreamingImages) {
        await camera.stopImageStream().timeout(const Duration(seconds: 3));
      }
    } catch (error) {
      debugPrint('Camera stream shutdown failed: $error');
    } finally {
      try {
        await camera.dispose().timeout(const Duration(seconds: 5));
      } catch (error) {
        debugPrint('Camera release failed: $error');
      }
    }
  }

  void _onCameraChanged() {
    final controller = _controller;
    if (!mounted || _disposing || controller == null) return;
    setState(() {});
    if (controller.value.hasError) {
      debugPrint('Camera error ${controller.value.errorDescription}');
      unawaited(restartCamera());
    }
  }

  Future<void> onViewFinderTap(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }
    final Offset offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    try {
      await cameraController.setExposurePoint(offset);
      await cameraController.setFocusPoint(offset);
    } on CameraException catch (error) {
      debugPrint('Camera focus failed: ${error.code}');
    }
    if (!mounted || _disposing || !identical(_controller, cameraController)) {
      return;
    }

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
