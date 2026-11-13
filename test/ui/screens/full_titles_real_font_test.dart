// The full-title tests again with the bundled Familjen Grotesk instead of
// the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../widgets/kit_harness.dart' show loadRealFonts;
import 'full_titles_test.dart' as full_titles;

void main() {
  setUpAll(loadRealFonts);
  full_titles.main();
}
