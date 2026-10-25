import 'package:integration_test/integration_test.dart';

import '../test/scanner/processing_cases.dart';
import '../test/scanner/camera_streaming_cases.dart';
import '../test/scanner/enhancement_refinement_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerProcessingTests();
  registerEnhancementRefinementTests();
  registerCameraStreamingTests();
}
