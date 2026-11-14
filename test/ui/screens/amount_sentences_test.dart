// VISUAL-R34-01 as a class: an amount inside a sentence is never split
// across lines, wherever the sentence is shown. A plain [Text] wraps an
// amount like any word and breaks it mid-amount when it is wider than its
// line ("KD99,999,999.99 / 9"); [FitWordsText] sets the sentence smaller
// instead. Every sentence that can carry an amount goes through it.
//
// - Source check: no plain Text in lib/ui shows a sentence built from an
//   amount (MoneyFormat.format, or a string builder that takes an amount)
//   on more than one line, and every dialog body and snack bar message,
//   which callers fill with any sentence, is a FitWordsText.
// - The "can't be removed yet" dialog for every member with an open
//   balance in the Money.maxMinor world (INR and KWD), over the charter
//   matrix.
// - A seeded property test: the shared confirm dialog and snack bar never
//   break an amount token, whatever the sentence, width and text scale.
//
// amount_sentences_real_font_test.dart runs this file again with the
// bundled Familjen Grotesk.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/visual/visual_harness.dart';
import '../widgets/kit_harness.dart' show kitApp;

/// Amount words of multi-line paragraphs on screen wider than their line
/// (so broken in the middle).
List<String> _brokenAmounts(String at) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final p = e.renderObject;
    if (p is! RenderParagraph || !p.hasSize || p.maxLines == 1) continue;
    final span = p.text;
    if (span is! TextSpan) continue;
    final text = span.toPlainText();
    for (final word in text.split(RegExp(r'\s+'))) {
      if (!RegExp(r'\d').hasMatch(word)) continue;
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
  }
  return out;
}

/// The argument list of the call whose "(" is at [open] in [s].
String _args(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')' && --depth == 0) return s.substring(open + 1, i);
  }
  return s.substring(open + 1);
}

/// String builders in the copy that take an amount ("Record $amount
/// payment"), as `S.name(` / `KitStrings.name(`.
Set<String> _amountBuilders() {
  final out = <String>{};
  final param = RegExp(
    r'static String (\w+)\(([^)]*)\)',
  ); // static String recordPayment(String amount)
  const amountParam =
      r'String\?? (amount|paid|share|spent|total|each|assigned|adjusted|'
      r'balance|open|max|zero|back)\b';
  for (final (file, owner) in [
    ('lib/ui/strings.dart', 'S'),
    ('lib/ui/widgets/kit_strings.dart', 'KitStrings'),
  ]) {
    for (final m in param.allMatches(File(file).readAsStringSync())) {
      if (RegExp(amountParam).hasMatch(m[2]!)) out.add('$owner.${m[1]}(');
    }
  }
  return out;
}

const _words = [
  'Sam',
  'has',
  'open',
  'in',
  'this',
  'group.',
  'Settle',
  'up',
  'first,',
  'then',
  'remove.',
  'Record',
  'payment',
  'Bartholomew',
]; // dart format off

void main() {
  configureVisualTests();

  test('no plain Text shows a sentence that carries an amount, and every '
      'dialog body and snack bar message is a FitWordsText', () {
    final builders = _amountBuilders();
    expect(builders, contains('S.cannotRemoveBody('));
    expect(builders, contains('S.recordPayment('));
    final problems = <String>[];
    final files = Directory('lib/ui')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in files) {
      final s = f.readAsStringSync();
      // A plain Text( or Text.rich( call: not FitWordsText, RichText ...
      for (final m in RegExp(r'(?<![\w.])Text(\.rich)?\(').allMatches(s)) {
        final args = _args(s, m.end - 1);
        if (RegExp(r'maxLines:\s*1\b').hasMatch(args)) continue; // one line
        final line = '${f.path}:${s.substring(0, m.start).split('\n').length}';
        if (args.contains('MoneyFormat.format(')) {
          problems.add('$line: a plain Text shows MoneyFormat.format');
        }
        for (final b in builders) {
          if (args.contains(b)) problems.add('$line: a plain Text shows $b');
        }
      }
      // Dialog bodies and snack bar messages take any sentence.
      for (final m in RegExp(
        r'(?<!\w)content:\s*Text\(', // a const Text is fixed copy
      ).allMatches(s)) {
        final line = '${f.path}:${s.substring(0, m.start).split('\n').length}';
        problems.add('$line: a dialog or snack bar body is a plain Text');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('the "can\'t be removed yet" dialog never splits '
      'Money.maxMinor, in INR or KWD, for any member', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.huge());
    final problems = <String>[];
    for (final v in kVariants) {
      for (final (gid, member) in [
        (w.kwdGroup, 'Sam K'),
        (w.group, 'Priya Sharma'),
      ]) {
        final at = '${variantName(v)} $member';
        await pumpVisual(t, w.phone, v: v, location: Routes.members(gid));
        await t.tap(find.text(member).first);
        await settleFrames(t);
        await t.tap(find.text(S.remove).last);
        await settleFrames(t);
        if (find.byType(AlertDialog).evaluate().isEmpty) {
          problems.add('$at: no dialog');
        }
        problems.addAll(_brokenAmounts(at));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: the shared dialog body and snack bar never break '
      'an amount', (t) async {
    final r = Random(3501);
    final amounts = [
      MoneyFormat.format(Money.maxMinor, 'KWD'),
      MoneyFormat.format(Money.maxMinor, 'INR'),
      MoneyFormat.format(-Money.maxMinor, 'USD'),
      MoneyFormat.format(Money.maxMinor, 'JPY'),
    ];
    final problems = <String>[];
    addTearDown(t.view.reset);
    for (var i = 0; i < 60; i++) {
      final words = [
        for (var k = 0, n = 2 + r.nextInt(10); k < n; k++)
          _words[r.nextInt(_words.length)],
      ]..insert(r.nextInt(3), amounts[r.nextInt(amounts.length)]);
      final sentence = words.join(' ');
      final width = 300.0 + r.nextInt(140);
      final scale = const [1.0, 1.3, 1.5, 2.0][r.nextInt(4)];
      final snack = r.nextBool();
      final at =
          '${snack ? 'snack' : 'dialog'} "$sentence" ${width.round()} dp '
          '@${scale}x';
      t.view.physicalSize = Size(width, 900) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => snack
                  ? showSnack(context, sentence)
                  : confirmAction(
                      context,
                      title: 'Title',
                      body: sentence,
                      confirmLabel: 'OK',
                    ),
              child: const Text('open'),
            ),
          ),
          textScale: scale,
          scroll: false,
        ),
      );
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      problems.addAll(_brokenAmounts(at));
      final ex = t.takeException();
      if (ex != null) problems.add('$at: $ex');
      await t.pumpWidget(const SizedBox.shrink());
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
