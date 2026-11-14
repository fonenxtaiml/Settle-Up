// VISUAL-R36-01 as a class: a phone's name in sync history (Sync's
// "Recent syncs" and the Activity feed's "Synced with ..." rows) wraps in
// full on each screen by itself. Neither row opens a view that shows the
// name, and Sync's header names only the latest sync's phone, so a capped
// name would read in full nowhere. Phone names are bounded at 40
// characters (SPEC 5.16), so a wrapped name takes at most a few lines.
//
// The names include one long unbroken word, wide letters, CJK and seeded
// random names up to the limit, on every charter size, scale and theme.
// sync_history_names_real_font_test.dart runs this file again with the
// bundled Familjen Grotesk.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/router.dart';

import '../../qa/visual/visual_harness.dart';

/// Whether [text] is shown somewhere on screen in full (never cut), alone
/// or inside a longer line.
bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().contains(text) &&
      !p.didExceedMaxLines;
});

SyncRecord _record(String peer, int minutes, {bool ok = true}) => SyncRecord(
  id: 'sync-names-$minutes',
  peerName: peer,
  transport: minutes.isEven ? TransportKind.lan : TransportKind.ble,
  startedAt: kNow.subtract(Duration(minutes: minutes + 1)),
  endedAt: kNow.subtract(Duration(minutes: minutes)),
  sentOps: 3,
  receivedOps: 2,
  groupIds: const [],
  outcome: ok ? SyncOutcome.completed : SyncOutcome.failed,
);

/// A seeded random phone name of 30 to 40 characters.
String _randomName(Random r) {
  const words = [
    'Bartholomew',
    'Fitzgerald',
    'Johnston',
    'Pixel',
    'Galaxy',
    'Ultra',
    'WWWWWWWW',
    'MMMMMM',
    'Xperia',
    'Redmi',
    'Note',
    'Pro',
    'Max',
    '8a',
    '9',
    'S24',
    'Moto',
    'Edge',
    'Nothing',
    'OnePlus',
  ];
  final target = 30 + r.nextInt(11);
  var s = '';
  while (s.length < target) {
    final w = words[r.nextInt(words.length)];
    final sep = s.isEmpty ? '' : (r.nextBool() ? ' ' : '-');
    s = '$s$sep$w';
  }
  return s.substring(0, min(s.length, 40)).trim();
}

/// [v] with a tall screen, so every row of a list is built.
Variant _tall(Variant v) =>
    (size: Size(v.size.width, 3200), scale: v.scale, brightness: v.brightness);

void main() {
  configureVisualTests();

  final r = Random(36);
  final names = <String>[
    'Bartholomew Fitzgerald-Johnston Pixel 8a',
    'W' * 40,
    'WWWWWWWWWW WWWWWWWWWW WWWWWWWWWW WWWWWWWW',
    '漢字電話漢字電話漢字電話漢字電話漢字電話漢字電話漢字電話漢字電話漢字電話漢字電話',
    for (var i = 0; i < 4; i++) _randomName(r),
  ];

  testWidgets('every phone name in sync history reads in full on Sync and '
      'on Activity, each by itself (VISUAL-R36-01)', (t) async {
    late VisualWorld w;
    await t.runAsync(() async {
      w = await VisualWorld.realistic();
      // History lists the last added first: oldest first, so names[0] is
      // the latest sync. One sync stopped early.
      for (final (i, n) in names.indexed.toList().reversed) {
        w.phone.engine.addHistory(_record(n, 2 + i, ok: i != 3));
      }
    });
    // Sync lists the five latest syncs; Activity lists every one.
    final onSync = names.take(5).toList();
    final problems = <String>[];
    for (final v in kVariants) {
      for (final (loc, expected) in [
        (Routes.sync, onSync),
        (Routes.activity, names),
      ]) {
        final at = '${variantName(v)} $loc';
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, w.phone, v: _tall(v), location: loc),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        for (final n in expected) {
          if (!_shownInFull(n)) problems.add('$at: "$n" is cut');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => w.phone.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
