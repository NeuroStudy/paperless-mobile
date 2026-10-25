import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/scanner/view/focusable_camera_view.dart';

import 'camera_test_support.dart';

void main() {
  testWidgets(
    'background invalidates a pending recognition startup immediately',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final camera = TestCameraController(initialized: false);
      final startup = Completer<void>();
      var published = false;
      var invalidated = false;
      await tester.pumpWidget(
        MaterialApp(
          home: FocusableCameraView(
            camera: testCamera,
            controllerFactory: () => camera,
            onControllerChanged: (controller) async {
              if (controller != null) {
                published = true;
                await startup.future;
              } else {
                invalidated = true;
                if (!startup.isCompleted) startup.complete();
              }
            },
          ),
        ),
      );
      await tester.pump();
      expect(published, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(invalidated, isTrue);
      await tester.pump();
      expect(camera.disposals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('background during initialization invalidates the old camera', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final first = TestCameraController(initialized: false)
      ..initialization = Completer<void>();
    final second = TestCameraController(initialized: false);
    final available = <CameraController?>[];
    var created = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FocusableCameraView(
          camera: testCamera,
          controllerFactory: () => created++ == 0 ? first : second,
          onControllerChanged: (controller) async {
            available.add(controller);
          },
        ),
      ),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    first.initialization!.complete();
    await tester.pump();
    await tester.pump();
    expect(first.disposals, 1);
    expect(available.whereType<CameraController>(), [second]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(second.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a flash setup error still publishes an initialized camera', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final camera = TestCameraController(initialized: false)..failFlash = true;
    CameraController? available;
    await tester.pumpWidget(
      MaterialApp(
        home: FocusableCameraView(
          camera: testCamera,
          controllerFactory: () => camera,
          onControllerChanged: (controller) async {
            available = controller;
          },
        ),
      ),
    );
    await tester.pump();
    expect(available, same(camera));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'closing while initialization is pending releases the late camera',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final camera = TestCameraController(initialized: false)
        ..initialization = Completer<void>();
      final available = <CameraController?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: FocusableCameraView(
            camera: testCamera,
            controllerFactory: () => camera,
            onControllerChanged: (controller) async {
              available.add(controller);
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      camera.initialization!.complete();
      await tester.pump();
      expect(available.whereType<CameraController>(), isEmpty);
      expect(camera.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
