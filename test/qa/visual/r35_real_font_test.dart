// QA VISUAL round 35: the round 35 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r35_sweep_test.dart' as r35;

void main() {
  setUpAll(loadRealFonts);
  r35.main();
}
