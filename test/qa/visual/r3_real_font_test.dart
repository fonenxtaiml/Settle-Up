// QA VISUAL round 3: the round 3 sweeps again with the bundled Familjen
// Grotesk instead of the test font. The test font draws every glyph as a
// 1 em square, so it is wider than the real font and a row that fits there
// can still choose a different layout (stack or not, group chip in the bar
// or not) with real glyphs. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r3_regression_test.dart' as r3;

void main() {
  setUpAll(loadRealFonts);
  r3.main();
}
