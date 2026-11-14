// QA VISUAL round 39: the round 39 sweep again with the bundled Familjen
// Grotesk instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'r39_sweep_test.dart' as r39;

void main() {
  setUpAll(loadRealFonts);
  r39.main();
}
