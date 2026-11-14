// QA VISUAL round 42: the round 42 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r42_sweep_test.dart' as r42;

void main() {
  setUpAll(loadRealFonts);
  r42.main();
}
