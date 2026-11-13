// VISUAL-R31-02, VISUAL-R32-01 and VISUAL-R32-02 as a class: a row's own
// words are never cut, and its text column is never narrower than a word.
//
// - A KitListRow without a line cap (every row of the app's own words: a
//   setting, a notice, a help line, an empty state) shows its title and
//   subline in full: no ellipsis, whatever the text, width or text scale.
// - Whatever the trailing block (a button, a switch, a value, an icon),
//   the text beside it keeps its widest word, 96 dp and half the row, or
//   the block goes under the text: no word is ever broken mid-word, and
//   the block never overlaps the text or leaves the row.
// - List entries that set a cap (a name) keep it.
// - The Home sync strip shows its status line in full in every state.
//
// The property tests draw seeded random texts, widths, text scales and
// trailing blocks. beside_or_below_r32_real_font_test.dart runs this file
// again with the bundled Familjen Grotesk.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/beside_or_below.dart';
import 'package:settle_up/ui/widgets/list_row.dart';
import 'package:settle_up/ui/widgets/sync_status.dart';

import 'kit_harness.dart';

const _words = [
  'a',
  'is',
  'on',
  'the',
  'phone',
  'Simplify',
  'debts',
  'in',
  'new',
  'groups',
  'Bluetooth',
  'Location',
  'permission',
  'Android',
  'Turn',
  'it',
  'Check',
  'date',
  'and',
  'time',
  'synced',
  'Konstantinopoulou',
  'hotspot',
  'settings',
  'हिन्दी',
  'தமிழ்',
  '名前',
  '!!',
]; // dart format off

const _labels = [
  'Allow',
  'Open settings',
  'Turn on Bluetooth',
  'Turn on location',
  'Sync',
  'View sync',
];

const _scales = [1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

String _text(Random r, {int maxWords = 20}) => [
  for (var i = 0, n = 1 + r.nextInt(maxWords); i < n; i++)
    _words[r.nextInt(_words.length)],
].join(' ');

Widget _trailing(Random r) => switch (r.nextInt(5)) {
  0 => FilledButton.tonal(
    onPressed: () {},
    child: Text(_labels[r.nextInt(_labels.length)]),
  ),
  1 => Switch(value: r.nextBool(), onChanged: (_) {}),
  2 => const Icon(Icons.chevron_right_rounded),
  3 => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Text(_text(r, maxWords: 4)),
      ),
      const Icon(Icons.chevron_right_rounded),
    ],
  ),
  _ => OutlinedButton(onPressed: () {}, child: const Text('Pair')),
};

/// Problems with the paragraphs under [of]: cut with an ellipsis, or a
/// word wider than the paragraph's column (so broken mid-word) that would
/// fit the widest column the row has ([widest], under its trailing block).
List<String> _textProblems(
  WidgetTester t,
  Finder of, {
  double widest = double.infinity,
}) {
  final out = <String>[];
  for (final e in find
      .descendant(of: of, matching: find.byType(RichText))
      .evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    final text = p.text.toPlainText();
    if (p.didExceedMaxLines) out.add('cut "$text"');
    if (p.maxLines == 1) continue; // A capped line ends in an ellipsis.
    // Lines may break at a space or after a hyphen.
    for (final word in text.split(RegExp(r'\s+|(?<=-)'))) {
      if (word.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(text: word, style: p.text.style),
        textScaler: p.textScaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > p.constraints.maxWidth + 0.5 && tp.width <= widest) {
        out.add(
          '"$word" is ${tp.width.round()} dp in a '
          '${p.constraints.maxWidth.round()} dp column',
        );
      }
      tp.dispose();
    }
  }
  return out;
}

void main() {
  configureKitTests();

  testWidgets('property: a row of the app\'s own words never cuts them and '
      'never squeezes them beside its trailing block', (t) async {
    final r = Random(3201);
    final problems = <String>[];
    for (var i = 0; i < 160; i++) {
      final width = 280.0 + r.nextInt(161);
      final scale = _scales[r.nextInt(_scales.length)];
      final title = _text(r, maxWords: 8);
      final help = r.nextBool() ? _text(r) : null;
      final leading = r.nextBool();
      final rtl = r.nextInt(4) == 0;
      final keepBeside = r.nextInt(4) == 0;
      t.view.physicalSize = Size(width, 2400) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: KitListRow(
              key: const Key('row'),
              title: title,
              subtitle: help,
              leading: leading ? const Icon(Icons.schedule) : null,
              keepTrailingBeside: keepBeside,
              trailing: KeyedSubtree(
                key: const Key('trailing'),
                child: _trailing(r),
              ),
            ),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
        ),
      );
      final at =
          '${width.round()} dp @${scale}x${rtl ? ' rtl' : ''}: '
          '"$title" / "${help ?? ''}"';
      // The widest column: the row less its insets and leading.
      final widest = width - 32 - (leading ? 24 + 14 : 0);
      // The row's text column (a value in the trailing block keeps its
      // own 160 dp box).
      final text = find
          .descendant(
            of: find.byType(BesideOrBelow),
            matching: find.byType(Column),
          )
          .first;
      for (final p in _textProblems(t, text, widest: widest)) {
        problems.add('$at: $p');
      }
      final box = t.renderObject<RenderBesideOrBelow>(
        find.byType(BesideOrBelow),
      );
      final row = t.getRect(find.byKey(const Key('row')));
      final tr = t.getRect(find.byKey(const Key('trailing')));
      final textRect = t.getRect(text);
      if (tr.left < row.left - 0.5 || tr.right > row.right + 0.5) {
        problems.add('$at: trailing block outside the row');
      }
      if (tr.overlaps(textRect.deflate(0.5))) {
        problems.add('$at: trailing block over the text');
      }
      if (box.trailingBeside && textRect.width + 0.5 < 96) {
        problems.add('$at: text ${textRect.width.round()} dp beside it');
      }
      // The trailing block keeps the end edge, beside or under the text.
      final endGap = rtl ? tr.left - row.left : row.right - tr.right;
      if ((endGap - 16).abs() > 0.5) {
        problems.add('$at: trailing block ${endGap.round()} dp from the end');
      }
      // The dry layout agrees with the real one.
      final dry = box.getDryLayout(box.constraints);
      if ((dry.height - box.size.height).abs() > 0.5) {
        problems.add('$at: dry ${dry.height} vs ${box.size.height}');
      }
      expect(t.takeException(), isNull);
    }
    t.view.reset();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('a list entry that sets a cap keeps it, beside or under its '
      'trailing block', (t) async {
    for (final scale in _scales) {
      t.view.physicalSize = const Size(320, 900) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          KitListRow(
            title: 'Maximiliana Konstantinopoulou-Rasmussen ' * 4,
            titleLines: 1,
            subtitle: 'In Goa trip, Flat, Office lunch ' * 6,
            subtitleLines: 1,
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
          textScale: scale,
        ),
      );
      final cut = [
        for (final e in find.byType(RichText).evaluate())
          if ((e.renderObject! as RenderParagraph).didExceedMaxLines) e,
      ];
      expect(cut, hasLength(2), reason: '@${scale}x');
      expect(t.takeException(), isNull);
    }
    t.view.reset();
  });

  testWidgets('the trailing block sits beside short text and goes under a '
      'long label that would leave it a sliver', (t) async {
    t.view.physicalSize = const Size(320, 900) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    Future<bool> beside(String title, {double scale = 1}) async {
      await t.pumpWidget(
        kitApp(
          KitListRow(
            title: title,
            leading: const Icon(Icons.bluetooth_disabled_rounded),
            trailing: FilledButton.tonal(
              onPressed: () {},
              child: const Text('Turn on Bluetooth'),
            ),
          ),
          textScale: scale,
        ),
      );
      return t
          .renderObject<RenderBesideOrBelow>(find.byType(BesideOrBelow))
          .trailingBeside;
    }

    expect(await beside('Wi-Fi'), isFalse); // a 320 dp phone: no room
    t.view.physicalSize = const Size(800, 900) * 3;
    expect(await beside('Bluetooth is off'), isTrue);
    expect(await beside('Bluetooth is off', scale: 2), isFalse);
  });

  for (final size in const [Size(320, 568), Size(360, 640), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      final at = '${size.width.round()} dp @${scale}x';
      testWidgets('the Home sync strip shows its status in full in every '
          'state at $at', (t) async {
        t.view.physicalSize = size * 3;
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        for (final state in SyncChipState.values) {
          for (final synced in [false, true]) {
            await t.pumpWidget(
              kitApp(
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SyncBanner(
                    state: state,
                    pendingCount: 12,
                    peerName: synced
                        ? 'Maximiliana Konstantinopoulou-Rasmussen'
                        : null,
                    lastSyncedAt: synced ? DateTime(2026, 11, 12, 9) : null,
                    now: DateTime(2026, 11, 13, 9),
                    onTap: () {},
                    onSync: () {},
                  ),
                ),
                textScale: scale,
              ),
            );
            // The widest column: the strip less the gutter, its padding,
            // the icon and its gap.
            expect(
              _textProblems(
                t,
                find.byType(SyncBanner),
                widest: size.width - 32 - 28 - 24 - 12,
              ),
              isEmpty,
              reason: '$state synced: $synced',
            );
            expect(t.takeException(), isNull);
          }
        }
      });
    }
  }
}
