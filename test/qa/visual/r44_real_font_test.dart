// QA VISUAL round 44: the round 44 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r44_sweep_test.dart' as r44;

void main() {
  setUpAll(loadRealFonts);
  r44.main();
}
