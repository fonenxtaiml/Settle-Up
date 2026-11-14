// QA VISUAL round 36: the round 36 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r36_sweep_test.dart' as r36;

void main() {
  setUpAll(loadRealFonts);
  r36.main();
}
