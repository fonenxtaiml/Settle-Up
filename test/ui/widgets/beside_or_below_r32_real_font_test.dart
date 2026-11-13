// beside_or_below_r32_test.dart again with the bundled Familjen Grotesk
// instead of the test font (each glyph a 1 em square). Both must pass.
import 'package:flutter_test/flutter_test.dart';

import 'beside_or_below_r32_test.dart' as r32;
import 'kit_harness.dart' show loadRealFonts;

void main() {
  setUpAll(loadRealFonts);
  r32.main();
}
