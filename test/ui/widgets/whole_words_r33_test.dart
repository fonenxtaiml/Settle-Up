// VISUAL-R31-02 (nearby row), VISUAL-R33-01, VISUAL-R33-02 and
// VISUAL-R33-03 as a class: the app's own words in a row, a tile, a table
// or a field are never cut with an ellipsis, and no column they are laid
// out in is narrower than one of their words.
//
// - NearbyPhoneRow shows its status line in full ("Bluetooth, shares Goa
//   trip and 2 more"), whatever the group name, width or text scale.
// - BeforeAfterTable (Settle up "What changes") stacks a row when the Now
//   and After columns would leave its label less than its widest word.
// - PickerTile never gives its value less than its widest word, and
//   PickerTilePair (Paid by | Date) stacks its tiles when half the row
//   would.
// - LabeledTextField shows its label and hint in full, puts the trailing
//   chip under the field when beside it the label or the hint would break
//   a word, keeps the chip where it is while the user types, and focuses
//   the field from a tap on the label.
// - KeyValueRow puts the value under the key when the key column or the
//   room beside it is narrower than a word ("Optional" at 2.0x).
//
// The property tests draw seeded random texts, widths and text scales.
// whole_words_r33_real_font_test.dart runs this file again with the
// bundled Familjen Grotesk.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/form_tiles.dart';
import 'package:settle_up/ui/widgets/list_section.dart';
import 'package:settle_up/ui/widgets/nearby.dart';
import 'package:settle_up/ui/widgets/settle_controls.dart';
import 'package:settle_up/ui/widgets/symbol_text.dart';

import 'kit_harness.dart';

const _words = [
  'a',
  'is',
  'on',
  'the',
  'Goa',
  'trip',
  'You',
  'and',
  'Sam',
  'overall',
  'All',
  'groups',
  'Your',
  'Kuwait',
  'Today,',
  'Yesterday,',
  'Wednesday,',
  '9',
  'Nov',
  'Description',
  'For',
  'example,',
  'Priya',
  'Bluetooth,',
  'Wi-Fi,',
  'shares',
  'more',
  'Konstantinopoulou',
  'हिन्दी',
  '名前',
]; // dart format off

const _scales = [1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

String _text(Random r, {int maxWords = 6}) => [
  for (var i = 0, n = 1 + r.nextInt(maxWords); i < n; i++)
    _words[r.nextInt(_words.length)],
].join(' ');

/// Paragraphs under [of] cut with an ellipsis, or with a word wider than
/// their column (so broken mid-word) that would fit [widest].
List<String> _problems(
  WidgetTester t,
  Finder of, {
  double widest = double.infinity,
  bool Function(String text)? skip,
}) {
  final out = <String>[];
  for (final e in find
      .descendant(of: of, matching: find.byType(RichText))
      .evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    if (!p.hasSize) continue;
    final text = p.text.toPlainText();
    if (skip?.call(text) ?? false) continue;
    if (p.didExceedMaxLines) out.add('cut "$text"');
    if (p.maxLines == 1) continue;
    for (final word in text.split(RegExp(r'\s+|(?<=-)'))) {
      if (word.isEmpty) continue;
      final tp = TextPainter(
        text: TextSpan(text: word, style: p.text.style),
        textScaler: p.textScaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > p.constraints.maxWidth + 0.5 && tp.width <= widest) {
        out.add(
          '"$word" of "$text" is ${tp.width.round()} dp in a '
          '${p.constraints.maxWidth.round()} dp column',
        );
      }
      tp.dispose();
    }
  }
  return out;
}

void _view(WidgetTester t, double width, {double height = 2400}) {
  t.view.physicalSize = Size(width, height) * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  configureKitTests();

  testWidgets('property: the nearby phone row shows its status line in full '
      '(VISUAL-R31-02)', (t) async {
    final r = Random(3301);
    final problems = <String>[];
    for (var i = 0; i < 80; i++) {
      final width = 300.0 + r.nextInt(121);
      final scale = _scales[r.nextInt(_scales.length)];
      final transport = ['Wi-Fi', 'Bluetooth', 'Nearby'][r.nextInt(3)];
      final status = switch (r.nextInt(4)) {
        0 => 'may share a group',
        1 => 'no shared groups',
        2 => 'shares ${_text(r, maxWords: 3)}',
        _ => 'shares ${_text(r, maxWords: 3)} and ${2 + r.nextInt(9)} more',
      };
      final sub = '$transport, $status';
      _view(t, width);
      await t.pumpWidget(
        kitApp(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListSection(
              children: [
                NearbyPhoneRow(
                  name: "Priya's Pixel 8",
                  subtitle: sub,
                  action: NearbyPhoneAction.values[r.nextInt(4)],
                  onAction: () {},
                ),
              ],
            ),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
        ),
      );
      final p = t.renderObject<RenderParagraph>(
        find.descendant(of: find.text(sub), matching: find.byType(RichText)),
      );
      if (p.didExceedMaxLines) {
        problems.add('${width.round()} dp @${scale}x: cut "$sub"');
      }
      expect(t.takeException(), isNull);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: "What changes" never breaks a label mid-word '
      '(VISUAL-R33-01)', (t) async {
    final r = Random(3302);
    final problems = <String>[];
    for (var i = 0; i < 80; i++) {
      final width = 300.0 + r.nextInt(141);
      final scale = _scales[r.nextInt(_scales.length)];
      final entries = [
        for (var j = 0, n = 1 + r.nextInt(4); j < n; j++)
          BeforeAfterEntry(
            title: _text(r, maxWords: 3),
            subtitle: r.nextBool() ? _text(r, maxWords: 3) : null,
            now: BalanceCell(
              word: 'you owe',
              minor: -r.nextInt(2000000),
              direction: MoneyDirection.owe,
            ),
            after: const BalanceCell(word: 'settled up', minor: 0),
          ),
      ];
      _view(t, width);
      await t.pumpWidget(
        kitApp(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: BeforeAfterTable(entries: entries, currency: 'KWD'),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
        ),
      );
      final at = '${width.round()} dp @${scale}x';
      // The widest a label can be: the card less its row padding.
      for (final p in _problems(
        t,
        find.byType(BeforeAfterTable),
        widest: width - 32 - 32,
        // The amounts keep their own fit (BalanceTrailing).
        skip: (text) => text.contains('KD') || text.contains('settled'),
      )) {
        problems.add('$at: $p');
      }
      expect(t.takeException(), isNull, reason: at);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('"What changes" keeps its columns where the labels fit '
      '(VISUAL-R33-01)', (t) async {
    const entries = [
      BeforeAfterEntry(
        title: 'You and Sam',
        subtitle: 'Kuwait Goa trip',
        now: BalanceCell(
          word: 'you owe',
          minor: -1250750,
          direction: MoneyDirection.owe,
        ),
        after: BalanceCell(word: 'settled up', minor: 0),
      ),
    ];
    for (final (width, stacked) in [(412.0, false), (320.0, true)]) {
      _view(t, width);
      await t.pumpWidget(
        kitApp(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: BeforeAfterTable(entries: entries, currency: 'KWD'),
          ),
        ),
      );
      // The Now / After heads sit above the columns only beside them.
      final heads = find.descendant(
        of: find.byType(ExcludeSemantics),
        matching: find.text('Now'),
      );
      expect(heads.evaluate().isEmpty, stacked, reason: '$width dp');
    }
  });

  testWidgets('property: a picker tile never gives its value less than its '
      'widest word, and Paid by | Date stacks before it would '
      '(VISUAL-R33-02)', (t) async {
    final r = Random(3303);
    final problems = <String>[];
    for (var i = 0; i < 80; i++) {
      final width = 300.0 + r.nextInt(121);
      final scale = _scales[r.nextInt(_scales.length)];
      final payer = _text(r, maxWords: 2);
      final date = _text(r, maxWords: 3);
      _view(t, width);
      await t.pumpWidget(
        kitApp(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PickerTilePair(
              first: PickerTile(
                label: 'Paid by',
                value: payer,
                leading: const Icon(Icons.group_outlined, size: 20),
                onTap: () {},
              ),
              second: PickerTile(
                label: 'Date',
                value: date,
                leading: const Icon(Icons.calendar_today_rounded, size: 20),
                onTap: () {},
              ),
            ),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
        ),
      );
      final at = '${width.round()} dp @${scale}x: "$payer" / "$date"';
      // The widest a value can be: a whole-width tile less its chrome.
      for (final p in _problems(
        t,
        find.byType(PickerTilePair),
        widest: width - 32 - 22 - 26 - 10 - 40,
      )) {
        problems.add('$at: $p');
      }
      expect(t.takeException(), isNull, reason: at);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('a picker tile with a wide symbol keeps its value whole '
      '(VISUAL-R33-02)', (t) async {
    final problems = <String>[];
    for (final width in [320.0, 360.0]) {
      for (final scale in _scales) {
        for (final value in [
          'Kuwaiti dinar (KWD)',
          'Bosnia and Herzegovina convertible mark (BAM)',
          'Today, 9 Nov',
        ]) {
          _view(t, width);
          await t.pumpWidget(
            kitApp(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: PickerTile(
                  label: 'Currency',
                  value: value,
                  leading: Builder(
                    builder: (context) => SymbolText(
                      'KD.',
                      style: Theme.of(context).textTheme.titleMedium,
                      maxWidth: SymbolText.maxLeadingWidth(context),
                    ),
                  ),
                  onTap: () {},
                ),
              ),
              textScale: scale,
            ),
          );
          for (final p in _problems(
            t,
            find.byType(PickerTile),
            // The symbol scales down in its slot (SymbolText).
            skip: (text) => text == 'KD.',
          )) {
            problems.add('${width.round()} dp @${scale}x: $p');
          }
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: a labelled field shows its label and hint in full '
      'and never breaks them beside its chip (VISUAL-R33-03)', (t) async {
    final r = Random(3304);
    final problems = <String>[];
    for (var i = 0; i < 80; i++) {
      final width = 300.0 + r.nextInt(121);
      final scale = _scales[r.nextInt(_scales.length)];
      final label = _text(r, maxWords: 3);
      final hint = r.nextBool() ? _text(r) : null;
      final chip = r.nextInt(3) != 0;
      final multiline = r.nextBool();
      _view(t, width);
      await t.pumpWidget(
        kitApp(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LabeledTextField(
              label: label,
              hintText: hint,
              multiline: multiline,
              trailing: chip
                  ? CategoryChip(
                      key: const Key('chip'),
                      categoryId: 'general',
                      label: _text(r, maxWords: 2),
                      onTap: () {},
                    )
                  : null,
            ),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
        ),
      );
      final at = '${width.round()} dp @${scale}x: "$label" / "${hint ?? ''}"';
      final field = find.byType(LabeledTextField);
      for (final p in _problems(
        t,
        field,
        // The widest the field's text can be: the field less its padding.
        widest: width - 32 - 28,
        // The chip label scales its own way (CategoryChip).
        skip: (text) =>
            chip &&
            find
                .descendant(
                  of: find.byKey(const Key('chip')),
                  matching: find.text(text),
                )
                .evaluate()
                .isNotEmpty,
      )) {
        problems.add('$at: $p');
      }
      final box = t.getRect(field);
      if (chip) {
        final c = t.getRect(find.byKey(const Key('chip')));
        if (c.left < box.left - 0.5 || c.right > box.right + 0.5) {
          problems.add('$at: chip outside the field');
        }
      }
      expect(t.takeException(), isNull, reason: at);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('a labelled field keeps its chip where it is while the user '
      'types a long word, and a tap on the label focuses it '
      '(VISUAL-R33-03, VISUAL-R8-01)', (t) async {
    _view(t, 360);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await t.pumpWidget(
      kitApp(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LabeledTextField(
            label: 'Description',
            hintText: 'For example, dinner',
            controller: controller,
            multiline: true,
            trailing: CategoryChip(
              key: const Key('chip'),
              categoryId: 'general',
              label: 'General',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    final before = t.getRect(find.byKey(const Key('chip')));
    await t.tap(find.text('Description'));
    await t.pump();
    expect(
      t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await t.enterText(find.byType(TextField), 'Supercalifragilistic' * 3);
    await t.pump();
    expect(t.getRect(find.byKey(const Key('chip'))).left, before.left);
    // TalkBack reads the label as the field's.
    final node = t.getSemantics(find.byType(TextField));
    expect(node.label, contains('Description'));
    expect(node.flagsCollection.isTextField, isTrue);
  });

  testWidgets('property: a key and value row never breaks a word in its '
      'key column or beside it', (t) async {
    final r = Random(3305);
    final problems = <String>[];
    for (var i = 0; i < 80; i++) {
      final width = 300.0 + r.nextInt(121);
      final scale = _scales[r.nextInt(_scales.length)];
      final label = _text(r, maxWords: 2);
      final value = r.nextBool() ? _text(r) : null;
      _view(t, width);
      await t.pumpWidget(
        kitApp(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListSection(
              children: [
                KeyValueRow(
                  label: label,
                  value: value,
                  placeholder: 'Optional',
                  onTap: r.nextBool() ? () {} : null,
                ),
              ],
            ),
          ),
          textScale: scale,
        ),
      );
      final at = '${width.round()} dp @${scale}x: "$label" / "$value"';
      for (final p in _problems(
        t,
        find.byType(KeyValueRow),
        widest: width - 32 - 28 - 20,
      )) {
        problems.add('$at: $p');
      }
      expect(t.takeException(), isNull, reason: at);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
