// VISUAL-R34-02 as a class: a row caps an entry's, a group's or a
// person's line because it reads in full one tap away, and the screen that
// tap opens shows it in full, never only in the one-line app bar.
//
// - The expense and payment detail screens name the kind of entry in the
//   app bar and show the entry's title (its description, or who paid
//   whom) as the body's heading, wrapped in full.
// - The group and person screens keep the name in the app bar and, while
//   the app bar cuts it, repeat it in full at the top of the body
//   (TitleCutScope, CutTitleHeading); a name that fits is not shown twice.
//
// The property test draws seeded random titles, widths and text scales.
// full_titles_real_font_test.dart runs this file again with the bundled
// Familjen Grotesk.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/app_chrome.dart';

import '../../qa/visual/visual_harness.dart';
import '../widgets/kit_harness.dart' show kitApp;

/// Paragraphs showing exactly [text], each as (in the app bar, cut,
/// a word broken).
List<(bool, bool, bool)> _shown(WidgetTester t, String text) => [
  for (final e in find.text(text).evaluate())
    if (find
            .descendant(
              of: find.byElementPredicate((x) => x == e),
              matching: find.byType(RichText),
            )
            .evaluate()
            .firstOrNull
            ?.renderObject
        case final RenderParagraph p)
      (
        find
            .ancestor(
              of: find.byElementPredicate((x) => x == e),
              matching: find.byType(AppBar),
            )
            .evaluate()
            .isNotEmpty,
        p.didExceedMaxLines,
        p.maxLines != 1 && _broken(p),
      ),
];

bool _broken(RenderParagraph p) {
  final span = p.text;
  for (final word in span.toPlainText().split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final tp = TextPainter(
      text: TextSpan(text: word, style: (span as TextSpan).style),
      textScaler: p.textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    tp.dispose();
    if (w > p.constraints.maxWidth + 0.5) return true;
  }
  return false;
}

const _words = [
  'Goa',
  'trip',
  'Dinner',
  'at',
  'the',
  'shack',
  'Bartholomew',
  'Konstantinopoulou',
  'Fitzgerald-Johnson',
  'and',
  'friends',
  'हिन्दी',
  '名前のグループ',
  'x',
]; // dart format off

void main() {
  configureVisualTests();

  testWidgets('every entry, group and person screen shows its title in '
      'full, and a title that fits is not shown twice', (t) async {
    late VisualWorld real, long;
    await t.runAsync(() async {
      real = await VisualWorld.realistic();
      long = await VisualWorld.longNames();
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final tall = (
        size: Size(v.size.width, 2400),
        scale: v.scale,
        brightness: v.brightness,
      );
      for (final (w, name, loc, text, inAppBar) in [
        (real, 'expense', real.screens['expense']!, 'Dinner at the shack', 0),
        (real, 'payment', real.screens['payment']!, 'Sam paid Priya', 0),
        (long, 'expense', long.screens['expense']!, kDesc120, 0),
        (long, 'payment', long.screens['payment']!, 'Sam paid Bartholomew', 0),
        (real, 'group', real.screens['group']!, 'Goa trip', 1),
        (long, 'group', long.screens['group']!, kGroup60, 1),
        (real, 'person', real.screens['person']!, 'Priya Sharma', 1),
        (long, 'person', long.screens['person']!, kName40, 1),
      ]) {
        final at = '${variantName(v)} $name "$text"';
        await pumpVisual(t, w.phone, v: tall, location: loc);
        final shown = _shown(t, text);
        final full = shown.where((s) => !s.$2 && !s.$3).length;
        final body = shown.where((s) => !s.$1).length;
        final barCut = shown.any((s) => s.$1 && s.$2);
        if (full == 0) problems.add('$at: never shown in full');
        if (shown.any((s) => s.$3)) problems.add('$at: a word broken');
        if (inAppBar == 1) {
          // The app bar keeps the name; the body repeats it only when cut.
          if (shown.where((s) => s.$1).isEmpty) {
            problems.add('$at: not in the app bar');
          }
          if (!barCut && body > 0) problems.add('$at: shown twice');
          if (barCut && body != 1) problems.add('$at: body shows it $body x');
        } else if (body != 1) {
          problems.add('$at: the body shows it $body times');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() async {
      await real.phone.dispose();
      await long.phone.dispose();
    });
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: CutTitleHeading shows the title in full exactly '
      'while the app bar cuts it', (t) async {
    final r = Random(3402);
    final problems = <String>[];
    for (var i = 0; i < 120; i++) {
      final title = [
        for (var k = 0, n = 1 + r.nextInt(8); k < n; k++)
          _words[r.nextInt(_words.length)],
      ].join(' ');
      final width = 280.0 + r.nextInt(200);
      final scale = const [1.0, 1.15, 1.3, 1.5, 2.0][r.nextInt(5)];
      final actions = r.nextInt(3);
      final dark = r.nextBool();
      final at = '"$title" ${width.round()} dp @${scale}x $actions actions';
      t.view.physicalSize = Size(width, 1600) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          TitleCutScope(
            child: Scaffold(
              appBar: AppBar(
                leading: const BackButton(),
                titleSpacing: 0,
                title: AppBarTitle(title, subtitle: 'Sub'),
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
          brightness: dark ? Brightness.dark : Brightness.light,
          scroll: false,
        ),
      );
      await t.pump();
      await t.pump();
      final shown = _shown(t, title);
      final barCut = shown.any((s) => s.$1 && s.$2);
      final body = shown.where((s) => !s.$1).toList();
      if (barCut != (body.length == 1)) {
        problems.add('$at: app bar cut $barCut, body shows ${body.length}');
      }
      if (body.any((s) => s.$2 || s.$3)) problems.add('$at: body cut/broken');
      final ex = t.takeException();
      if (ex != null) problems.add('$at: $ex');
    }
    t.view.reset();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
