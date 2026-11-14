// The nearby phone name tests again with the bundled Familjen Grotesk
// instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../widgets/kit_harness.dart' show loadRealFonts;
import 'nearby_phone_names_test.dart' as nearby_phone_names;

void main() {
  setUpAll(loadRealFonts);
  nearby_phone_names.main();
}
