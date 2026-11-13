// QA VISUAL round 33: the round 33 sweep again with the bundled Familjen
// Grotesk instead of the test font (each glyph a 1 em square, wider than
// the real font). Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r33_sweep_test.dart' as r33;

void main() {
  setUpAll(loadRealFonts);
  r33.main();
}
