// QA VISUAL round 5: reverification of the round 4 layout fixes (the Sync
// tether, the amount field, the expense editor split rows, the expense
// detail and balance rows) and what those fixes changed.
//
// Tests named "QA VISUAL-R5-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

Variant v5(double w, double scale, [Brightness b = Brightness.light]) => (
  size: Size(w, w <= 320 ? 568 : (w < 384 ? 640 : 800)),
  scale: scale,
  brightness: b,
);

double _longestWord(RenderParagraph p) {
  var widest = 0.0;
  for (final word in p.text.toPlainText().split(RegExp(r'\s+'))) {
    final tp = TextPainter(
      text: TextSpan(text: word, style: p.text.style),
      textDirection: p.textDirection,
      textScaler: p.textScaler,
    )..layout();
    if (tp.width > widest) widest = tp.width;
    tp.dispose();
  }
  return widest;
}

/// Paragraphs under [scope] narrower than their longest word: a name cut
/// inside its first word, or an amount broken over two lines.
List<String> _squeezed(Finder scope, String where) => [
  for (final e
      in find.descendant(of: scope, matching: find.byType(RichText)).evaluate())
    if (e.renderObject case final RenderParagraph p)
      if (p.hasSize && p.size.width + 0.5 < _longestWord(p))
        '$where: "${p.text.toPlainText()}" gets '
            '${p.size.width.toStringAsFixed(1)} dp < its longest word '
            '${_longestWord(p).toStringAsFixed(1)} dp',
];

/// KitListRows with a trailing block whose title or subline is narrower
/// than its longest word.
List<String> _squeezedRows(WidgetTester tester, String where) {
  final out = <String>[];
  for (final r in find.byType(KitListRow).evaluate()) {
    final row = r.widget as KitListRow;
    if (row.trailing == null) continue;
    for (final t in [row.title, ?row.subtitle]) {
      final f = find.descendant(of: find.byWidget(row), matching: find.text(t));
      if (f.evaluate().isEmpty) continue;
      final p = tester.renderObject<RenderParagraph>(f.first);
      if (p.size.width + 0.5 < _longestWord(p)) {
        out.add(
          '$where: "$t" gets ${p.size.width.toStringAsFixed(1)} dp < '
          '${_longestWord(p).toStringAsFixed(1)} dp',
        );
      }
    }
  }
  return out;
}

/// The share field (EditableText) whose controller is [c].
Finder _fieldOf(TextEditingController c) => find.byWidgetPredicate(
  (w) => w is EditableText && identical(w.controller, c),
);

/// Opens the realistic expense in the editor (split by exact amounts) and
/// focuses a share field: Priya's "120000.50", or Sam's empty one after
/// ticking Sam in. Returns its controller.
Future<TextEditingController> _focusShare(
  WidgetTester tester,
  VisualWorld w,
  Variant v, {
  required bool sam,
}) async {
  await pumpVisual(
    tester,
    w.phone,
    v: v,
    location: Routes.editExpense(w.expense),
  );
  await tester.scrollUntilVisible(
    find.text('Priya'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  if (sam) {
    final box = find.byWidgetPredicate(
      (x) => x is Checkbox && x.semanticLabel == 'Sam',
    );
    await tester.ensureVisible(box);
    await tester.pump();
    await tester.tap(box);
    await tester.pump();
  }
  final share = sam
      ? find
            .byWidgetPredicate(
              (x) =>
                  x is EditableText &&
                  x.controller.text.isEmpty &&
                  !x.readOnly &&
                  x.keyboardType ==
                      const TextInputType.numberWithOptions(decimal: true),
            )
            .last
      : find.byWidgetPredicate(
          (x) => x is EditableText && x.controller.text == '120000.50',
        );
  await tester.ensureVisible(share);
  await tester.pump();
  await tester.tap(share);
  await tester.pump();
  return (share.evaluate().first.widget as EditableText).controller;
}

/// Types [steps] into the focused field one value at a time, and returns
/// the first step after which the field no longer has focus (the keyboard
/// closed), or null.
Future<String?> _typeUntilFocusLost(
  WidgetTester tester,
  TextEditingController c,
  List<String> steps,
) async {
  for (final text in steps) {
    if (!tester.testTextInput.hasAnyClients) return 'before "$text"';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await tester.pump();
    final f = _fieldOf(c);
    final focused =
        f.evaluate().isNotEmpty &&
        (f.evaluate().first.widget as EditableText).focusNode.hasFocus;
    if (!focused || !tester.testTextInput.hasAnyClients) return 'after "$text"';
  }
  return null;
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Guards for the round 4 fixes (these pass).
  // ------------------------------------------------------------------

  testWidgets('the Sync tether never overflows and never cuts a label word '
      '(280-371 dp content, 1.0x-2.0x, idle, active and connected, both '
      'themes)', (tester) async {
    final problems = <String>[];
    for (final w in const [320.0, 340.0, 360.0, 384.0, 411.0]) {
      for (final s in const [1.0, 1.3, 1.4, 1.45, 1.5, 1.55, 1.59, 1.6, 2.0]) {
        for (final b in Brightness.values) {
          for (final (name, t) in const [
            ('idle', SyncTether()),
            ('active', SyncTether(active: true)),
            ('connected', SyncTether(connected: true)),
          ]) {
            setView(tester, Size(w, 640));
            tester.platformDispatcher.textScaleFactorTestValue = s;
            final where = '${w.toInt()} dp @${s}x ${b.name} $name';
            final errors = await collectLayoutErrors(() async {
              await tester.pumpWidget(
                MaterialApp(
                  theme: b == Brightness.light
                      ? AppTheme.light()
                      : AppTheme.dark(),
                  home: Scaffold(
                    body: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: t,
                    ),
                  ),
                ),
              );
              await tester.pump(const Duration(milliseconds: 300));
            });
            for (final e in errors.toSet()) {
              problems.add('$where: $e');
            }
            problems.addAll(_squeezed(find.byType(SyncTether), where));
          }
        }
      }
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  for (final (name, build) in [
    ('realistic', VisualWorld.realistic),
    ('huge', VisualWorld.huge),
  ]) {
    testWidgets('Home, Person and expense detail rows keep the longest word '
        'or stack, with no overflow, between the round 4 scales ($name)', (
      tester,
    ) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await build());
      final kwd = w.phone.gs(w.kwdGroup).expenses.keys.first;
      final problems = <String>[];
      for (final width in const [320.0, 340.0, 384.0]) {
        for (final s in const [1.35, 1.45, 1.55]) {
          final v = v5(
            width,
            s,
            s == 1.45 ? Brightness.dark : Brightness.light,
          );
          for (final (sn, loc) in [
            ('home', Routes.home),
            ('person', Routes.person(w.person)),
            ('expense', Routes.expense(w.expense)),
            ('expense KWD', Routes.expense(kwd)),
          ]) {
            final where = '${variantName(v)} $sn';
            final errors = await collectLayoutErrors(
              () => pumpVisual(tester, w.phone, v: v, location: loc),
            );
            for (final e in errors.toSet()) {
              problems.add('$where: $e');
            }
            problems.addAll(_squeezedRows(tester, where));
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('the amount field shows the whole of Money.maxMinor typed in '
      'INR and KWD at 320-411 dp, 1.0x-2.0x', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final problems = <String>[];
    for (final width in const [320.0, 360.0, 411.0]) {
      for (final s in const [1.0, 1.3, 1.59, 2.0]) {
        final v = v5(width, s);
        for (final (g, typed) in [
          (w.group, '9999999999.99'),
          (w.kwdGroup, '99999999.999'),
        ]) {
          await pumpVisual(
            tester,
            w.phone,
            v: v,
            location: Routes.newExpense(groupId: g),
          );
          final field = find.descendant(
            of: find.byType(AmountField),
            matching: find.byType(EditableText),
          );
          await tester.enterText(field, typed);
          await tester.pump();
          final ed = field.evaluate().single;
          final text = (ed.widget as EditableText).controller.text;
          RenderEditable? re;
          void visit(RenderObject r) {
            if (r is RenderEditable) {
              re ??= r;
              return;
            }
            r.visitChildren(visit);
          }

          visit(ed.renderObject!);
          final start = re!
              .getLocalRectForCaret(const TextPosition(offset: 0))
              .left;
          final end = re!
              .getLocalRectForCaret(TextPosition(offset: text.length))
              .left;
          if (start < -1 || end > re!.size.width + 1) {
            problems.add('${variantName(v)}: "$text" partly out of sight');
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // New findings, round 5 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R5-01: the keyboard closes while typing a share in the '
    'expense editor when the split row switches between beside and stacked',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      // Deleting digits from Priya's ₹1,20,000.50 share, one key at a time.
      for (final v in [v5(320, 1.0), v5(360, 1.3), v5(411, 1.45)]) {
        final c = await _focusShare(tester, w, v, sam: false);
        final lost = await _typeUntilFocusLost(tester, c, [
          for (var i = 8; i >= 0; i--) '120000.50'.substring(0, i),
        ]);
        if (lost != null) {
          problems.add(
            '${variantName(v)}: deleting from "120000.50", the field lost '
            'focus $lost (now "${c.text}")',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      // Typing ₹1,20,000.50 into Sam's empty share, one key at a time.
      for (final v in [v5(320, 1.3), v5(320, 1.3, Brightness.dark)]) {
        final c = await _focusShare(tester, w, v, sam: true);
        final lost = await _typeUntilFocusLost(tester, c, [
          for (var i = 1; i <= 9; i++) '120000.50'.substring(0, i),
        ]);
        if (lost != null) {
          problems.add(
            '${variantName(v)}: typing "120000.50" into Sam\'s share, the '
            'field lost focus $lost (now "${c.text}")',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R5-02: equal-split rows on the expense editor break the '
    'share amount, squeeze the name and overflow (₹1,20,000.50 at 320 dp)',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final (g, typed, variants) in [
        (
          w.group,
          '120000.50',
          [
            v5(320, 1.0),
            v5(320, 1.59),
            v5(320, 2.0),
            v5(360, 1.3, Brightness.dark),
            v5(384, 1.45),
          ],
        ),
        (w.kwdGroup, '99999999.999', [v5(320, 1.3), v5(360, 1.5)]),
      ]) {
        for (final v in variants) {
          final where = '${variantName(v)} new expense, $typed split equally';
          await pumpVisual(
            tester,
            w.phone,
            v: v,
            location: Routes.newExpense(groupId: g),
          );
          final field = find.descendant(
            of: find.byType(AmountField),
            matching: find.byType(EditableText),
          );
          final errors = await collectLayoutErrors(() async {
            await tester.enterText(field, typed);
            await tester.pump();
            await tester.scrollUntilVisible(
              find.text('Sam'),
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pump();
          });
          for (final e in errors.toSet()) {
            problems.add('$where: $e');
          }
          problems.addAll(_squeezed(find.byType(MemberSplitRow), where));
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R4-03 (reopened in round 5): a stacked split row still breaks '
    'its share amount over two lines with Money.maxMinor at 1.8x-2.0x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.huge());
      final kwd = w.phone.gs(w.kwdGroup).expenses.keys.first;
      final problems = <String>[];
      for (final (id, v) in [
        (kwd, v5(320, 1.8)),
        (kwd, v5(320, 2.0)),
        (kwd, v5(340, 2.0)),
        (w.expense, v5(320, 2.0, Brightness.dark)),
      ]) {
        final where = '${variantName(v)} edit expense';
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(id),
        );
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -2000),
        );
        await tester.pump(const Duration(milliseconds: 300));
        for (final e in find.byType(RichText).evaluate()) {
          final p = e.renderObject as RenderParagraph;
          if (!p.hasSize) continue;
          final t = p.text.toPlainText();
          if (!kPureAmount.hasMatch(t.trim())) continue;
          final word = p.getMinIntrinsicWidth(double.infinity);
          if (p.size.width + 0.5 < word) {
            problems.add(
              '$where: "$t" broken over lines (box '
              '${p.size.width.toStringAsFixed(1)} < ${word.toStringAsFixed(1)})',
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
