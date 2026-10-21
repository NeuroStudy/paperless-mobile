import 'package:integration_test/integration_test.dart';

import '../packages/paperless_mobile_document_scanner/test/camera_input_case.dart';
import '../test/scanner/processing_cases.dart';
import '../test/scanner/recognition_cases.dart';
import '../test/scanner/worker_lifecycle_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerProcessingTests();
  registerRecognitionTests();
  registerWorkerLifecycleTests();
  registerCameraInputTest();
}
