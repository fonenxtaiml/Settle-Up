// app_bar_cuts_test.dart again with the bundled Familjen Grotesk instead
// of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../widgets/kit_harness.dart' show loadRealFonts;
import 'app_bar_cuts_test.dart' as cuts;

void main() {
  setUpAll(loadRealFonts);
  cuts.main();
}
