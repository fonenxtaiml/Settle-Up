// QA VISUAL round 41: the round 41 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r41_sweep_test.dart' as r41;

void main() {
  setUpAll(loadRealFonts);
  r41.main();
}
