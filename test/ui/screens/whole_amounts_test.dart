// VISUAL-R34-01 as a class: an amount is never split across lines. An
// amount inside a sentence (a row's subline "Sam paid KD99,999,999.999",
// the Settle up button "Record KD99,999,999.999 payment", a summary, a
// field's help or error line) wraps like any word, so when it is wider
// than its line the text is set smaller until it fits whole, as the pure
// amount texts already scale.
//
// - Every screen of the Money.maxMinor world (INR ₹99,99,99,999.99 and
//   KWD KD99,999,999.999) over the charter matrix, light and dark.
// - The amount forms after typing the largest amount and one past it, in
//   both currencies, so the help, summary and error lines carry it too.
// - A seeded property test: KitListRow's subline and FitWordsText never
//   break an amount token, whatever the sentence, width and text scale.
//
// whole_amounts_real_font_test.dart runs this file again with the bundled
// Familjen Grotesk.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_layout.dart';
import 'package:settle_up/ui/widgets/list_row.dart';

import '../../qa/visual/visual_harness.dart';
import '../widgets/kit_harness.dart' show kitApp;

/// A word that carries an amount: a digit next to a group or decimal
/// separator or a currency sign.
final _amountWord = RegExp(r'\d[\d,.]*\d|\d');

/// Amount words of multi-line paragraphs on screen wider than their line
/// (so broken in the middle).
List<String> _brokenAmounts(WidgetTester t, String at) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final p = e.renderObject;
    if (p is! RenderParagraph || !p.hasSize || p.maxLines == 1) continue;
    out.addAll(_brokenIn(p, at));
  }
  return out;
}

List<String> _brokenIn(RenderParagraph p, String at) {
  final out = <String>[];
  final span = p.text;
  if (span is! TextSpan) return out;
  final text = span.toPlainText();
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty || !_amountWord.hasMatch(word) || word.contains(':')) {
      continue; // an address (192.168.43.1:52741), not an amount
    }
    if (!RegExp(r'\d{3}').hasMatch(word.replaceAll(RegExp('[,.]'), ''))) {
      continue; // not an amount: "2", "9 Nov"
    }
    final tp = TextPainter(
      text: TextSpan(text: word, style: span.style),
      textScaler: p.textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width;
    tp.dispose();
    if (w > p.constraints.maxWidth + 0.5) {
      out.add(
        '$at: "$word" of "$text" is ${w.round()} dp in a '
        '${p.constraints.maxWidth.round()} dp line',
      );
    }
  }
  return out;
}

Variant _tall(Variant v) =>
    (size: Size(v.size.width, 2400), scale: v.scale, brightness: v.brightness);

void main() {
  configureVisualTests();

  testWidgets('no screen of the Money.maxMinor world splits an amount '
      'across lines', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.huge());
    final screens = {
      ...w.screens,
      'group activity': Routes.groupActivity(w.group),
      'edit payment': Routes.editExpense(w.payment),
      'new expense KWD': Routes.newExpense(groupId: w.kwdGroup),
    };
    final problems = <String>{};
    for (final v in kVariants) {
      for (final MapEntry(key: name, value: loc) in screens.entries) {
        final at = '${variantName(v)} $name';
        await pumpVisual(t, w.phone, v: _tall(v), location: loc);
        problems.addAll(_brokenAmounts(t, at));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('the amount forms never split the largest amount, or one '
      'past it, across lines', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.huge());
    final problems = <String>{};
    for (final v in kVariants) {
      for (final (name, loc, typed) in [
        (
          'new expense INR',
          Routes.newExpense(groupId: w.group),
          ['999999999.99', '1000000000'],
        ),
        (
          'new expense KWD',
          Routes.newExpense(groupId: w.kwdGroup),
          ['99999999.999', '100000000'],
        ),
        (
          'settle KWD',
          Routes.settle(groupId: w.kwdGroup),
          ['99999999.998', '100000000'],
        ),
        ('edit payment', Routes.editExpense(w.payment), ['1000000000']),
      ]) {
        for (final text in typed) {
          final at = '${variantName(v)} $name "$text"';
          await pumpVisual(t, w.phone, v: _tall(v), location: loc);
          final sheet = name.startsWith('settle');
          if (sheet) {
            // Settle up changes its amount in the "How much?" sheet.
            await t.tap(find.text(S.payPartOfIt));
            await settleFrames(t);
          }
          await t.enterText(find.byType(EditableText).first, text);
          await settleFrames(t);
          problems.addAll(_brokenAmounts(t, at));
          if (sheet) {
            final done = find.widgetWithText(FilledButton, S.done);
            if (t.widget<FilledButton>(done).onPressed != null) {
              await t.tap(done);
              await settleFrames(t);
              problems.addAll(_brokenAmounts(t, '$at, done'));
            }
          }
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: a row subline and FitWordsText never split an '
      'amount across lines', (t) async {
    final r = Random(3401);
    const currencies = ['INR', 'KWD', 'JPY', 'USD', 'EUR', 'BHD'];
    const words = ['Sam', 'paid', 'Record', 'payment', 'you', 'get', 'back'];
    final problems = <String>[];
    for (var i = 0; i < 150; i++) {
      final currency = currencies[r.nextInt(currencies.length)];
      final minor = switch (r.nextInt(3)) {
        0 => Money.maxMinor,
        1 => Money.maxMinor - r.nextInt(1 << 30),
        _ => r.nextInt(1 << 31),
      };
      final amount = MoneyFormat.format(minor, currency);
      final sentence = [
        for (var k = 0, n = r.nextInt(4); k < n; k++)
          words[r.nextInt(words.length)],
        amount,
        for (var k = 0, n = r.nextInt(3); k < n; k++)
          words[r.nextInt(words.length)],
      ].join(' ');
      final width = 140.0 + r.nextInt(240);
      final scale = const [1.0, 1.3, 1.5, 2.0][r.nextInt(4)];
      final at = '"$sentence" ${width.round()} dp @${scale}x';
      await t.pumpWidget(
        kitApp(
          Center(
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  KitListRow(title: 'Dinner', subtitle: sentence),
                  FitWordsText(sentence),
                ],
              ),
            ),
          ),
          textScale: scale,
        ),
      );
      for (final e in find.byType(RichText).evaluate()) {
        final p = e.renderObject;
        if (p is RenderParagraph && p.maxLines != 1) {
          problems.addAll(_brokenIn(p, at));
        }
      }
      final ex = t.takeException();
      if (ex != null) problems.add('$at: $ex');
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
