// QA VISUAL: every main screen at 320x568 and 360x640, text scale 1.0,
// 1.3 and 2.0, light and dark, over the real Ledger. A screen passes when
// no layout error is reported and no stand-alone amount is cut.
//
// Screen and world pairs with a known defect are skipped here and have a
// failing repro in layout_defects_test.dart (QA VISUAL-R1-NN).
import 'package:flutter_test/flutter_test.dart';

import 'visual_harness.dart';

/// (world, screen) -> finding id.
const Map<(String, String), String> kKnown = {};

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
