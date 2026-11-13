// QA VISUAL round 32: the round 32 sweep again with the bundled Familjen
// Grotesk instead of the test font (each glyph a 1 em square, wider than
// the real font). Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r32_sweep_test.dart' as r32;

void main() {
  setUpAll(loadRealFonts);
  r32.main();
}
