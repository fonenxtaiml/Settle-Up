// QA VISUAL round 34: the round 34 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r34_sweep_test.dart' as r34;

void main() {
  setUpAll(loadRealFonts);
  r34.main();
}
