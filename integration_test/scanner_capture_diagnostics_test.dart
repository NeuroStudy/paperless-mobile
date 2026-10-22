import 'package:integration_test/integration_test.dart';

import '../packages/paperless_mobile_document_scanner/test/capture_comparison_case.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerCaptureComparisonTest((report) => binding.reportData = report);
}
