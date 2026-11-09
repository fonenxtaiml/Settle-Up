// QA VISUAL: every main screen at 320x568 and 360x640, text scale 1.0,
// 1.3 and 2.0, light and dark, over the real Ledger. A screen passes when
// no layout error is reported and no stand-alone amount is cut.
//
// Screen and world pairs with a known defect are skipped here and have a
// failing repro in layout_defects_test.dart (QA VISUAL-R1-NN).
import 'package:flutter_test/flutter_test.dart';

import 'visual_harness.dart';

/// (world, screen) -> finding id.
const Map<(String, String), String> kKnown = {
  ('realistic', 'home'): 'VISUAL-R1-02',
  ('realistic', 'group'): 'VISUAL-R1-03',
  ('realistic', 'group KWD'): 'VISUAL-R1-03',
  ('realistic', 'settle'): 'VISUAL-R1-03',
  ('realistic', 'settle KWD'): 'VISUAL-R1-04',
  ('realistic', 'expense'): 'VISUAL-R1-01',
  ('realistic', 'payment'): 'VISUAL-R1-01',
  ('long names', 'home'): 'VISUAL-R1-02',
  ('long names', 'group'): 'VISUAL-R1-03',
  ('long names', 'settle'): 'VISUAL-R1-03',
  ('long names', 'settle KWD'): 'VISUAL-R1-04',
  ('long names', 'expense'): 'VISUAL-R1-01',
  ('long names', 'payment'): 'VISUAL-R1-01',
  ('long names', 'edit expense'): 'VISUAL-R1-05',
  ('long names', 'new expense'): 'VISUAL-R1-05',
  ('huge', 'home'): 'VISUAL-R1-02',
  ('huge', 'group'): 'VISUAL-R1-03',
  ('huge', 'group KWD'): 'VISUAL-R1-03',
  ('huge', 'settle'): 'VISUAL-R1-03',
  ('huge', 'settle KWD'): 'VISUAL-R1-04',
  ('huge', 'expense'): 'VISUAL-R1-01',
  ('huge', 'payment'): 'VISUAL-R1-01',
  ('huge', 'activity'): 'VISUAL-R1-08',
};

void main() {
  configureVisualTests();

  final worlds = <String, Future<VisualWorld> Function()>{
    'realistic': VisualWorld.realistic,
    'long names': VisualWorld.longNames,
    'huge': VisualWorld.huge,
  };
  // Screen names are fixed; ids are filled in once the world is built.
  const screens = [
    'home',
    'group',
    'group KWD',
    'activity',
    'search',
    'sync',
    'settle',
    'settle KWD',
    'person',
    'expense',
    'payment',
    'edit expense',
    'new expense',
    'members',
    'settings',
    'edit group',
    'invite',
  ];

  for (final world in worlds.entries) {
    for (final screen in screens) {
      final known = kKnown[(world.key, screen)];
      testWidgets(
        '${world.key}: $screen fits at every size, scale and theme'
        '${known == null ? '' : ' (QA $known)'}',
        skip: known != null,
        (tester) async {
          late VisualWorld w;
          await tester.runAsync(() async => w = await world.value());
          final problems = <String>[];
          for (final v in kVariants) {
            final r = await inspect(tester, w, v, w.screens[screen]!);
            final cut = pureOnly(r.cut);
            if (r.errors.isNotEmpty || cut.isNotEmpty) {
              problems.add('${variantName(v)}: ${r.errors.toSet()} $cut');
            }
          }
          await tester.runAsync(w.phone.dispose);
          expect(problems, isEmpty);
        },
      );
    }
  }
}
