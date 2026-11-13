// whole_words_r33_test.dart again with the bundled Familjen Grotesk
// instead of the test font (each glyph a 1 em square). Both must pass.
import 'package:flutter_test/flutter_test.dart';

import 'kit_harness.dart' show loadRealFonts;
import 'whole_words_r33_test.dart' as r33;

void main() {
  setUpAll(loadRealFonts);
  r33.main();
}
