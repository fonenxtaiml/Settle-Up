// amount_sentences_test.dart again with the bundled Familjen Grotesk
// instead of the test font. Both must pass.
import 'package:flutter_test/flutter_test.dart';

import '../widgets/kit_harness.dart' show loadRealFonts;
import 'amount_sentences_test.dart' as sentences;

void main() {
  setUpAll(loadRealFonts);
  sentences.main();
}
