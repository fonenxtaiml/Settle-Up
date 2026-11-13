// QA VISUAL round 31: the round 31 dialog sweep again with the bundled
// Familjen Grotesk instead of the test font (each glyph a 1 em square,
// wider than the real font). Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r31_sweep_test.dart' as r31;

void main() {
  setUpAll(loadRealFonts);
  r31.main();
}
