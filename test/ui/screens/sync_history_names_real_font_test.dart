// The sync history name tests again with the bundled Familjen Grotesk
// instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../widgets/kit_harness.dart' show loadRealFonts;
import 'sync_history_names_test.dart' as sync_history_names;

void main() {
  setUpAll(loadRealFonts);
  sync_history_names.main();
}
