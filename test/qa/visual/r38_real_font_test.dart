// QA VISUAL round 38: the round 38 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r38_sweep_test.dart' as r38;

void main() {
  setUpAll(loadRealFonts);
  r38.main();
}
