// QA VISUAL round 37: the round 37 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r37_sweep_test.dart' as r37;

void main() {
  setUpAll(loadRealFonts);
  r37.main();
}
