// The whole-amount tests again with the bundled Familjen Grotesk instead of
// the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../widgets/kit_harness.dart' show loadRealFonts;
import 'whole_amounts_test.dart' as whole_amounts;

void main() {
  setUpAll(loadRealFonts);
  whole_amounts.main();
}
