import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile_document_scanner/models/auto_capture_config.dart';
import 'package:paperless_mobile_document_scanner/paperless_mobile_document_scanner.dart';
import 'package:paperless_mobile_document_scanner/view/document_scanner_view.dart';
import 'package:paperless_mobile_document_scanner/view/focusable_camera_view.dart';

const _camera = CameraDescription(
  name: 'lifecycle-test',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

// Exercise the real CameraController/CameraPreview against a controllable native
// host. Initialization/flash can finish after the scanner has been unmounted.
class _CameraHost extends CameraPlatform {
  final calls = <MethodCall>[];
  Completer<void>? initializeGate;
  Completer<void>? flashGate;
  Completer<void>? disposeGate;
  int _nextId = 0;

  final _initialized = StreamController<CameraInitializedEvent>.broadcast();
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  void install(WidgetTester tester) {
    final previous = CameraPlatform.instance;
    CameraPlatform.instance = this;
    addTearDown(() => CameraPlatform.instance = previous);
    // The document preview's spirit level subscribes even without detection.
    for (final channel in const [
      MethodChannel('dev.fluttercommunity.plus/sensors/accelerometer'),
      MethodChannel('dev.fluttercommunity.plus/sensors/method'),
    ]) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
    }
  }

  int count(String method) => calls.where((c) => c.method == method).length;

  @override
  Future<List<CameraDescription>> availableCameras() async => [_camera];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    calls.add(MethodCall('create', mediaSettings));
    return _nextId++;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    calls.add(MethodCall('initialize', cameraId));
    await initializeGate?.future;
    _initialized.add(
      CameraInitializedEvent(
        cameraId,
        640,
        480,
        ExposureMode.auto,
        true,
        FocusMode.auto,
        true,
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream.where((event) => event.cameraId == cameraId);

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      _errors.stream.where((event) => event.cameraId == cameraId);

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream<DeviceOrientationChangedEvent>.empty();

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {
    calls.add(MethodCall('setFlashMode', cameraId));
    await flashGate?.future;
  }

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => StreamController<CameraImageData>(
    onListen: () => calls.add(MethodCall('startImageStream', cameraId)),
    onCancel: () => calls.add(MethodCall('stopImageStream', cameraId)),
  ).stream;

  @override
  Widget buildPreview(int cameraId) => const SizedBox.expand();

  @override
  Future<void> dispose(int cameraId) async {
    calls.add(MethodCall('dispose', cameraId));
    await disposeGate?.future;
  }
}

Widget _view(ValueChanged<CameraController> initialized) => MaterialApp(
  home: FocusableCameraView(
    camera: _camera,
    onControllerInitialized: initialized,
  ),
);

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void registerCameraLifecycleTests() {
  final resolutionCases = <(String, Widget, ResolutionPreset)>[
    (
      'scanner default',
      PaperlessMobileDocumentScanner(
        liveDetectionInitiallyEnabled: false,
        autoCaptureConfig: const AutoCaptureConfig(enabled: false),
        onCancelled: (_) {},
        onDone: (_) {},
      ),
      ResolutionPreset.ultraHigh,
    ),
    (
      'scanner override',
      PaperlessMobileDocumentScanner(
        resolutionPreset: ResolutionPreset.high,
        liveDetectionInitiallyEnabled: false,
        autoCaptureConfig: const AutoCaptureConfig(enabled: false),
        onCancelled: (_) {},
        onDone: (_) {},
      ),
      ResolutionPreset.high,
    ),
    (
      'document view default',
      DocumentScannerView(
        camera: _camera,
        liveEdgeDetectionEnabled: false,
        onControllerInitialized: (_) {},
        onAutoCaptureTriggered: (_) {},
      ),
      ResolutionPreset.ultraHigh,
    ),
    (
      'document view override',
      DocumentScannerView(
        camera: _camera,
        resolutionPreset: ResolutionPreset.high,
        liveEdgeDetectionEnabled: false,
        onControllerInitialized: (_) {},
        onAutoCaptureTriggered: (_) {},
      ),
      ResolutionPreset.high,
    ),
    (
      'focusable view default',
      FocusableCameraView(camera: _camera, onControllerInitialized: (_) {}),
      ResolutionPreset.ultraHigh,
    ),
    (
      'focusable view override',
      FocusableCameraView(
        camera: _camera,
        resolutionPreset: ResolutionPreset.high,
        onControllerInitialized: (_) {},
      ),
      ResolutionPreset.high,
    ),
  ];
  for (final (label, view, expected) in resolutionCases) {
    testWidgets('$label reaches the native camera', (tester) async {
      final host = _CameraHost()..install(tester);
      await tester.pumpWidget(MaterialApp(home: view));
      await _flush(tester);
      final settings =
          host.calls.singleWhere((c) => c.method == 'create').arguments
              as MediaSettings;
      expect(settings.resolutionPreset, expected);
      expect(settings.enableAudio, isFalse);
      expect(find.byType(CameraPreview), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(host.count('dispose'), 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('closing an initialized preview without a stream is safe', (
    tester,
  ) async {
    final host = _CameraHost()..install(tester);
    await tester.pumpWidget(_view((_) {}));
    await _flush(tester);
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    expect(tester.takeException(), isNull);
    expect(host.count('stopImageStream'), 0);
    expect(host.count('dispose'), 1);
  });

  testWidgets('closing after capture already stopped the stream is safe', (
    tester,
  ) async {
    final host = _CameraHost()..install(tester);
    CameraController? controller;
    await tester.pumpWidget(
      _view((value) {
        controller = value;
        value.startImageStream((_) {});
      }),
    );
    await _flush(tester);
    await tester.runAsync(controller!.stopImageStream);
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    expect(tester.takeException(), isNull);
    expect(host.count('stopImageStream'), 1);
    expect(host.count('dispose'), 1);
  });

  testWidgets(
    'resume waits for shutdown before opening one replacement camera',
    (tester) async {
      final host = _CameraHost()
        ..disposeGate = Completer<void>()
        ..install(tester);
      var published = 0;
      await tester.pumpWidget(_view((_) => published++));
      await _flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(host.count('create'), 1);
      host.disposeGate!.complete();
      await _flush(tester);
      expect(host.count('create'), 2);
      expect(published, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(host.count('dispose'), 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inactive initialization cannot publish an old camera on resume',
    (tester) async {
      final host = _CameraHost()
        ..initializeGate = Completer<void>()
        ..install(tester);
      final controllers = <CameraController>[];
      await tester.pumpWidget(_view(controllers.add));
      await _flush(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      host.initializeGate!.complete();
      await _flush(tester);
      expect(host.count('create'), 2);
      expect(host.count('setFlashMode'), 1);
      expect(controllers.single.cameraId, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(host.count('dispose'), 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing a streaming preview detaches listeners before stopping',
    (tester) async {
      final host = _CameraHost()..install(tester);
      CameraController? controller;
      await tester.pumpWidget(
        _view((value) {
          controller = value;
          value.startImageStream((_) {});
        }),
      );
      await _flush(tester);
      expect(controller!.value.isStreamingImages, isTrue);
      expect(find.byType(CameraPreview), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(host.count('stopImageStream'), 1);
      expect(host.count('dispose'), 1);
    },
  );

  testWidgets(
    'closing during initialization cannot publish a stale controller',
    (tester) async {
      final host = _CameraHost()
        ..initializeGate = Completer<void>()
        ..install(tester);
      var published = 0;
      await tester.pumpWidget(_view((_) => published++));
      await _flush(tester);
      expect(host.count('initialize'), 1);

      await tester.pumpWidget(const SizedBox.shrink());
      host.initializeGate!.complete();
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(published, 0);
      expect(host.count('setFlashMode'), 0);
      expect(host.count('dispose'), 1);
    },
  );

  testWidgets(
    'closing during flash initialization cannot publish a controller',
    (tester) async {
      final host = _CameraHost()
        ..flashGate = Completer<void>()
        ..install(tester);
      var published = 0;
      await tester.pumpWidget(_view((_) => published++));
      await _flush(tester);
      expect(host.count('setFlashMode'), 1);

      await tester.pumpWidget(const SizedBox.shrink());
      host.flashGate!.complete();
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(published, 0);
      expect(host.count('dispose'), 1);
    },
  );
}
