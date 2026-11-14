// VISUAL-R34-02 as a class: nothing the one-line app bar cuts is lost. An
// [AppBarTitle] reports what it cuts (its title, or a subline such as the
// group of the screen) and the screen's [CutTitleHeading] shows it in
// full; in debug builds an AppBarTitle that cuts a line on a screen with
// no heading reports an error, so a screen cannot miss it.
//
// - Every titled screen of the editor-maximum world (60-character group,
//   40-character name, 120-character description), including the group
//   waiting for its first sync, the group's Activity, Members, Invite and
//   both Settle up screens, over the charter matrix: every line the app
//   bar cuts reads in full in the body, with no error.
// - The debug check fires for a cut line without a heading, and not with
//   one or for a line that fits.
// - A seeded property test over random titles and sublines, widths, text
//   scales and actions: the heading shows exactly the lines the app bar
//   cuts, each in full, and nothing when both fit.
//
// app_bar_cuts_real_font_test.dart runs this file again with the bundled
// Familjen Grotesk.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/app_chrome.dart';

import '../../qa/visual/visual_harness.dart';
import '../widgets/kit_harness.dart' show kitApp;

Variant _tall(Variant v) =>
    (size: Size(v.size.width, 2400), scale: v.scale, brightness: v.brightness);

/// The paragraphs on screen, each as (text, in the app bar, cut).
List<(String, bool, bool)> _paragraphs() => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p when p.hasSize)
      (
        p.text.toPlainText(),
        find
            .ancestor(
              of: find.byElementPredicate((x) => x == e),
              matching: find.byType(AppBar),
            )
            .evaluate()
            .isNotEmpty,
        p.didExceedMaxLines,
      ),
];

/// Lines the app bar cuts that the body does not show in full.
List<String> _lost(String at) {
  final ps = _paragraphs();
  return [
    for (final (text, inBar, cut) in ps)
      if (inBar && cut && !ps.any((q) => !q.$2 && !q.$3 && q.$1 == text))
        '$at: the app bar cuts "$text" and the body does not show it',
  ];
}

const _words = [
  'Goa',
  'trip',
  'Dinner',
  'Bartholomew',
  'Konstantinopoulou',
  'and',
  'friends',
  'हिन्दी',
  '名前のグループ',
  'x',
]; // dart format off

String _phrase(Random r, int most) => [
  for (var k = 0, n = 1 + r.nextInt(most); k < n; k++)
    _words[r.nextInt(_words.length)],
].join(' ');

void main() {
  configureVisualTests();

  testWidgets('every titled screen shows in full whatever its app bar cuts, '
      'and none reports a missing heading', (t) async {
    late VisualWorld w;
    const pending = 'cccc0000-0000-7000-8000-000000000002';
    await t.runAsync(() async {
      w = await VisualWorld.longNames();
      await w.phone.ledger.registerJoinedGroup(
        pending,
        Uint8List(32),
        kGroup60,
      );
    });
    final routes = {
      ...w.screens,
      'group activity': Routes.groupActivity(w.group),
      'pending group': Routes.group(pending),
      'members KWD': Routes.members(w.kwdGroup),
    };
    final problems = <String>[];
    for (final v in kVariants) {
      for (final MapEntry(key: name, value: loc) in routes.entries) {
        final at = '${variantName(v)} $name';
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, w.phone, v: _tall(v), location: loc),
        );
        problems
          ..addAll(errors.map((e) => '$at: $e'))
          ..addAll(_lost(at));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  Widget screen(String title, {String? subtitle, bool heading = true}) =>
      kitApp(
        TitleCutScope(
          child: Scaffold(
            appBar: AppBar(
              title: AppBarTitle(title, subtitle: subtitle),
              actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.edit))],
            ),
            body: Column(
              children: [if (heading) const CutTitleHeading(), const Text('Body')],
            ),
          ),
        ),
        scroll: false,
      );

  testWidgets('debug builds report a cut app bar line with no heading on its '
      'screen', (t) async {
    t.view.physicalSize = const Size(320, 640) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(screen(kGroup60, heading: false));
    await t.pump();
    expect(
      '${t.takeException()}',
      contains('cuts "$kGroup60" and its screen has no CutTitleHeading'),
    );

    // A cut subline counts too.
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpWidget(screen('Members', subtitle: kGroup60, heading: false));
    await t.pump();
    expect('${t.takeException()}', contains('cuts "$kGroup60"'));

    // Outside any scope as well.
    await t.pumpWidget(
      kitApp(
        Scaffold(appBar: AppBar(title: const AppBarTitle(kGroup60))),
        scroll: false,
      ),
    );
    await t.pump();
    expect('${t.takeException()}', contains('no TitleCutScope'));

    // With a heading, or when the lines fit, nothing is reported.
    final first = screen(kGroup60);
    for (final s in [
      first,
      screen('Members', subtitle: kGroup60),
      screen('Goa trip', subtitle: 'Goa trip', heading: false),
    ]) {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpWidget(s);
      await t.pump();
      await t.pump();
      expect(t.takeException(), isNull);
      if (s == first) {
        expect(find.text(kGroup60), findsNWidgets(2)); // bar and body
      }
    }
  });

  testWidgets('property: the heading shows exactly the lines the app bar '
      'cuts, each in full', (t) async {
    final r = Random(3502);
    final problems = <String>[];
    addTearDown(t.view.reset);
    for (var i = 0; i < 120; i++) {
      final title = _phrase(r, 8);
      var subtitle = r.nextInt(4) == 0 ? null : _phrase(r, 6);
      if (subtitle == title) subtitle = '$subtitle x';
      final width = 280.0 + r.nextInt(200);
      final scale = const [1.0, 1.15, 1.3, 1.5, 2.0][r.nextInt(5)];
      final actions = r.nextInt(3);
      final at =
          '"$title" / "$subtitle" ${width.round()} dp @${scale}x '
          '$actions actions';
      t.view.physicalSize = Size(width, 1600) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          TitleCutScope(
            child: Scaffold(
              appBar: AppBar(
                leading: const BackButton(),
                titleSpacing: 0,
                title: AppBarTitle(title, subtitle: subtitle),
                actions: [
                  for (var a = 0; a < actions; a++)
                    IconButton(onPressed: () {}, icon: const Icon(Icons.edit)),
                ],
              ),
              body: const SingleChildScrollView(
                child: Column(children: [CutTitleHeading(), Text('Body')]),
              ),
            ),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
          scroll: false,
        ),
      );
      await t.pump();
      await t.pump();
      final ps = _paragraphs();
      for (final line in [title, ?subtitle]) {
        final barCut = ps.any((p) => p.$1 == line && p.$2 && p.$3);
        final body = ps.where((p) => p.$1 == line && !p.$2).toList();
        if (barCut && (body.length != 1 || body.single.$3)) {
          problems.add('$at: "$line" cut, the body shows it ${body.length}x');
        }
        if (!barCut && body.isNotEmpty && line != 'Body') {
          problems.add('$at: "$line" fits but is shown twice');
        }
      }
      final ex = t.takeException();
      if (ex != null) problems.add('$at: $ex');
      await t.pumpWidget(const SizedBox.shrink());
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
