// VISUAL-R36-01 as a class, Nearby: a nearby phone's name wraps in full in
// its row whatever the row's action. The row opens nothing, and Pair (a
// phone that shares no group) only explains how to join, so a capped name
// would read in full nowhere, and two phones of one owner that differ only
// at the end of their names would look the same.
//
// Two checks: the Sync screen with nearby phones of every kind (sharing a
// group, sharing none) on every charter size, scale and theme; and the row
// by itself with every action (Sync, Pair, busy, none) and names up to the
// most a peer's HELLO may carry (kMaxDeviceNameLength, 100 UTF-16 units),
// seeded random names included. nearby_phone_names_real_font_test.dart
// runs this file again with the bundled Familjen Grotesk.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/nearby.dart';

import '../../qa/visual/visual_harness.dart';
import '../widgets/kit_harness.dart' as kit;

/// Whether [text] is shown somewhere on screen in full (never cut), alone
/// or inside a longer line.
bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().contains(text) &&
      !p.didExceedMaxLines;
});

/// A seeded random phone name of 20 to [max] characters, with long words,
/// wide letters, hyphens and CJK.
String _randomName(Random r, int max) {
  const words = [
    'Bartholomew',
    'Fitzgerald',
    'Johnston',
    'Pixel',
    'Galaxy',
    'WWWWWWWWWW',
    'MMMMMM',
    'Xperia',
    '漢字電話',
    'Note',
    'Pro',
    '8a',
    '9',
    'S24',
    'OnePlus',
  ];
  final target = 20 + r.nextInt(max - 19);
  var s = '';
  while (s.length < target) {
    final w = words[r.nextInt(words.length)];
    final sep = s.isEmpty ? '' : (r.nextBool() ? ' ' : '-');
    s = '$s$sep$w';
  }
  return s.substring(0, min(s.length, max)).trim();
}

/// [v] with a tall screen, so every row of a list is built.
Variant _tall(Variant v) =>
    (size: Size(v.size.width, 3200), scale: v.scale, brightness: v.brightness);

void main() {
  configureVisualTests();

  final r = Random(37);
  const a = 'Bartholomew Fitzgerald-Johnston Pixel 8a';
  const b = 'Bartholomew Fitzgerald-Johnston Pixel 9';
  final names40 = <String>[
    a,
    b,
    'W' * 40,
    'WWWWWWWWWW WWWWWWWWWW WWWWWWWWWW WWWWWWWW',
    for (var i = 0; i < 3; i++) _randomName(r, 40),
  ];
  final names100 = <String>[
    '${'Bartholomew Fitzgerald-Johnston ' * 3}Pixel',
    'W' * 100,
    '漢' * 100,
    for (var i = 0; i < 4; i++) _randomName(r, 100),
  ];

  testWidgets('every nearby phone\'s name reads in full on Sync, whether it '
      'shares a group (Sync) or not (Pair) (VISUAL-R36-01)', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final peers = [
      for (final (i, n) in names40.indexed)
        NearbyPeer(
          key: 'k$i',
          name: n,
          transports: {i.isEven ? TransportKind.lan : TransportKind.ble},
          sharedGroupIds: i.isEven ? <GroupId>[] : [w.group],
        ),
    ];
    final problems = <String>[];
    for (final v in kVariants) {
      final at = variantName(v);
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, w.phone, v: _tall(v), location: Routes.sync);
        w.phone.engine.emitNearby(peers);
        await settleFrames(t);
      });
      problems.addAll(errors.map((e) => '$at: $e'));
      expect(find.byType(NearbyPhoneRow), findsNWidgets(peers.length));
      for (final n in names40) {
        if (!_shownInFull(n)) problems.add('$at: "$n" is cut');
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(() => w.phone.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('a nearby phone\'s name up to HELLO\'s limit reads in full '
      'with every action, at every size, scale and theme', (t) async {
    final problems = <String>[];
    for (final v in kVariants) {
      for (final action in NearbyPhoneAction.values) {
        final at = '${variantName(v)} ${action.name}';
        t.view.physicalSize = v.size * 3;
        t.view.devicePixelRatio = 3;
        final errors = await collectLayoutErrors(() async {
          await t.pumpWidget(
            kit.kitApp(
              Column(
                children: [
                  for (final n in names100)
                    NearbyPhoneRow(
                      name: n,
                      subtitle: 'Wi-Fi, may share a group',
                      action: action,
                      onAction: () {},
                    ),
                ],
              ),
              brightness: v.brightness,
              textScale: v.scale,
            ),
          );
          await t.pump(const Duration(milliseconds: 800));
        });
        problems.addAll(errors.map((e) => '$at: $e'));
        for (final n in names100) {
          if (!_shownInFull(n)) problems.add('$at: "$n" is cut');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    t.view.reset();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
