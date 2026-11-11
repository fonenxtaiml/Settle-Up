// QA VISUAL round 21, final regression sweep: the free-text prompt the
// notes counter changes of rounds 18 to 20 touched (lib/ui/screens/
// common.dart), and the places a note at the 1000-character cap is shown.
// The Settle up note prompt holds a full multi-line note with the keyboard
// up at every charter size, scale and theme without layout errors, with
// its counter whole and Save reachable; Settle up then shows the note in
// its row; the expense detail shows a full note and an edit history of
// Money.maxMinor amounts whole; the expense and payment editors hold the
// full note; and the prompt's counter stays on one line in the bundled
// font.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'visual_harness.dart';

/// 20 lines of 48 characters joined by 19 line breaks: 979 characters,
/// inside the 1000-character notes cap.
final String _note = List.generate(
  20,
  (i) => 'Line ${i.toString().padLeft(2, '0')} ${'x' * 40}',
).join('\n');

/// A phone keyboard: 260 dp on a 568 dp phone, 290 dp on 640.
double _keyboardDp(Variant v) => v.size.height < 600 ? 260 : 290;

FakeViewPadding _keyboard(Variant v) =>
    FakeViewPadding(bottom: _keyboardDp(v) * 3);

SemanticsNode? _node(WidgetTester t, Pattern label) {
  final f = find.semantics.byLabel(label);
  return f.evaluate().isEmpty ? null : f.evaluate().first;
}

/// Semantic tap on the first node whose label matches [label], scrolling
/// the page until it is built.
Future<bool> _semanticTap(WidgetTester t, Pattern label) async {
  for (var i = 0; i < 12 && _node(t, label) == null; i++) {
    final s = find.byWidgetPredicate(
      (x) =>
          x is Scrollable &&
          axisDirectionToAxis(x.axisDirection) == Axis.vertical,
    );
    if (s.evaluate().isEmpty) break;
    final pos = t.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await t.pump(const Duration(milliseconds: 200));
  }
  if (_node(t, label) == null) return false;
  t.semantics.tap(find.semantics.byLabel(label).first);
  await t.pump();
  return true;
}

/// A paragraph holding [text] (whole) that ran past its line limit.
bool _cut(WidgetTester t, String text) {
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is RenderParagraph && ro.text.toPlainText() == text) {
      return ro.didExceedMaxLines;
    }
  }
  return true;
}

void main() {
  configureVisualTests();

  testWidgets('the Settle up note prompt holds a full multi-line note with '
      'the keyboard up at every size, scale and theme, its counter whole and '
      'Save on screen; Settle up then shows the note', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.huge());
    final members = w.phone.gs(w.group).members.values;
    final friend = members.firstWhere((m) => m.personId == w.person).id;
    final me = members.firstWhere((m) => m.personId == w.phone.me).id;
    final settle = Routes.settle(groupId: w.group, from: friend, to: me);
    final problems = <String>[];
    for (final v in kVariants) {
      var opened = false;
      var counter = '';
      var saveShown = false;
      var noteShown = false;
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, w.phone, v: v, location: settle);
        if (!await _semanticTap(t, RegExp(r'^Note, '))) return;
        await settleFrames(t);
        opened = find.byType(AlertDialog).evaluate().isNotEmpty;
        if (!opened) return;
        t.view.viewInsets = _keyboard(v);
        await t.pump();
        await t.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(EditableText),
          ),
          _note,
        );
        await settleFrames(t);
        counter = '${_note.length}/1000';
        if (_cut(t, counter)) problems.add('${variantName(v)}: $counter cut');
        final save = find.widgetWithText(FilledButton, 'Save');
        if (save.evaluate().isNotEmpty) {
          final r = t.getRect(save);
          final screen = Offset.zero & v.size;
          saveShown =
              screen.contains(r.topLeft) &&
              r.bottom <= v.size.height - _keyboardDp(v) + 0.5;
          await t.tap(save, warnIfMissed: false);
          await settleFrames(t);
        }
        t.view.resetViewInsets();
        await settleFrames(t);
        // The row may sit below the fold once the prompt closes; its
        // label carries the note.
        noteShown = semanticsLabels(t)
            .any((s) => s.startsWith('Note, Line 00'));
      });
      if (errors.isNotEmpty || !opened || !saveShown || !noteShown) {
        problems.add(
          '${variantName(v)} opened=$opened save=$saveShown '
          'note=$noteShown: '
          '${errors.toSet()}',
        );
      }
      if (opened && find.byType(AlertDialog).evaluate().isNotEmpty) {
        problems.add('${variantName(v)}: Save did not close the prompt');
      }
      final cut = pureOnly(findCutAmounts(t));
      if (cut.isNotEmpty) problems.add('${variantName(v)}: $cut');
      t.view.resetViewInsets();
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(w.phone.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('the expense detail shows a full note and an edit history of '
      'Money.maxMinor amounts whole at every size, scale and theme, within '
      'the tap target, label and contrast guidelines', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async {
      w = await VisualWorld.huge();
      final g = w.phone.gs(w.group);
      final e = g.expenses[w.expense]!;
      final me = g.members.values.firstWhere((m) => m.personId == w.phone.me);
      final f = g.members.values.firstWhere((m) => m.personId == w.person);
      const total = Money.maxMinor - 1;
      await w.phone.ledger.updateExpense(
        w.expense,
        ExpenseDraft(
          groupId: w.group,
          description: e.description,
          total: total,
          currency: 'INR',
          paidBy: SplitSpec.single(me.id, total),
          owedBy: SplitSpec.single(f.id, total),
          category: e.category,
          date: e.date,
          notes: _note,
        ),
      );
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final r = await inspect(t, w, v, Routes.expense(w.expense));
      if (r.errors.isNotEmpty || r.cut.isNotEmpty) {
        problems.add('${variantName(v)}: ${r.errors.toSet()} ${r.cut}');
      }
    }
    for (final b in Brightness.values) {
      const size = Size(360, 640);
      final v = (size: size, scale: 1.0, brightness: b);
      await pumpVisual(t, w.phone, v: v, location: Routes.expense(w.expense));
      final texts = visibleTexts(t);
      if (!texts.any((s) => s.contains('Line 00'))) {
        problems.add('${variantName(v)}: note not shown');
      }
      for (final g in [
        androidTapTargetGuideline,
        labeledTapTargetGuideline,
        textContrastGuideline,
      ]) {
        final e = await g.evaluate(t);
        if (!e.passed) {
          problems.add(
            '${variantName(v)}: '
            '${(e.reason ?? '').split('\n').take(3).join(' ')}',
          );
        }
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(w.phone.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('the expense editor holds a full note with the keyboard up at '
      'every size, scale and theme', (t) async {
    late VisualWorld w;
    await t.runAsync(() async {
      w = await VisualWorld.longNames();
      final g = w.phone.gs(w.group);
      final e = g.expenses[w.expense]!;
      final me = g.members.values.firstWhere((m) => m.personId == w.phone.me);
      final f = g.members.values.firstWhere((m) => m.personId == w.person);
      await w.phone.ledger.updateExpense(
        w.expense,
        ExpenseDraft(
          groupId: w.group,
          description: e.description,
          total: e.money.total,
          currency: 'INR',
          paidBy: SplitSpec.single(me.id, e.money.total),
          owedBy: SplitSpec.single(f.id, e.money.total),
          category: e.category,
          date: e.date,
          notes: _note,
        ),
      );
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(
          t,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        t.view.viewInsets = _keyboard(v);
        await settleFrames(t);
        final s = find.byWidgetPredicate(
          (x) =>
              x is Scrollable &&
              axisDirectionToAxis(x.axisDirection) == Axis.vertical,
        );
        if (s.evaluate().isNotEmpty) {
          final pos = t.state<ScrollableState>(s.first).position;
          pos.jumpTo(pos.maxScrollExtent);
          await settleFrames(t);
        }
      });
      final cut = pureOnly(findCutAmounts(t));
      if (errors.isNotEmpty || cut.isNotEmpty) {
        problems.add('${variantName(v)}: ${errors.toSet()} $cut');
      }
      t.view.resetViewInsets();
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty);
  });

  testWidgets('a payment with a full note fits on its detail and in its '
      'editor with the keyboard up at every size, scale and theme', (t) async {
    late VisualWorld w;
    await t.runAsync(() async {
      w = await VisualWorld.huge();
      final g = w.phone.gs(w.group);
      final p = g.expenses[w.payment]!;
      final from = p.money.paid.keys.single;
      final to = p.money.owed.keys.single;
      await w.phone.ledger.updatePayment(
        w.payment,
        PaymentDraft(
          groupId: w.group,
          from: from,
          to: to,
          amount: Money.maxMinor,
          currency: 'INR',
          method: PaymentMethod.bank,
          date: p.date,
          notes: _note,
        ),
      );
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final r = await inspect(t, w, v, Routes.expense(w.payment));
      if (r.errors.isNotEmpty || r.cut.isNotEmpty) {
        problems.add('${variantName(v)} detail: ${r.errors.toSet()} ${r.cut}');
      }
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(
          t,
          w.phone,
          v: v,
          location: Routes.editExpense(w.payment),
        );
        t.view.viewInsets = _keyboard(v);
        await settleFrames(t);
        final s = find.byWidgetPredicate(
          (x) =>
              x is Scrollable &&
              axisDirectionToAxis(x.axisDirection) == Axis.vertical,
        );
        if (s.evaluate().isNotEmpty) {
          final pos = t.state<ScrollableState>(s.first).position;
          pos.jumpTo(pos.maxScrollExtent);
          await settleFrames(t);
        }
      });
      final cut = pureOnly(findCutAmounts(t));
      if (errors.isNotEmpty || cut.isNotEmpty) {
        problems.add('${variantName(v)} editor: ${errors.toSet()} $cut');
      }
      t.view.resetViewInsets();
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty);
  });

  // Last: the bundled fonts stay loaded for the rest of the file.
  group('with Familjen Grotesk', () {
    setUpAll(loadRealFonts);

    testWidgets('the note prompt counter stays on one line, empty and at '
        'the cap, at every size, scale and theme', (t) async {
      final handle = t.ensureSemantics();
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.huge());
      final members = w.phone.gs(w.group).members.values;
      final friend = members.firstWhere((m) => m.personId == w.person).id;
      final me = members.firstWhere((m) => m.personId == w.phone.me).id;
      final settle = Routes.settle(groupId: w.group, from: friend, to: me);
      // Topped up to the 1000-character cap.
      final full = _note + '.' * (1000 - _note.length);
      final counter = RegExp(r'^\d+/1000$');
      final problems = <String>[];
      for (final v in kVariants) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, w.phone, v: v, location: settle);
          if (!await _semanticTap(t, RegExp(r'^Note, '))) {
            problems.add('${variantName(v)}: no note row');
            return;
          }
          await settleFrames(t);
          t.view.viewInsets = _keyboard(v);
          final field = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(EditableText),
          );
          for (final text in ['', full]) {
            await t.enterText(field, text);
            await settleFrames(t);
            final shown = <String>[];
            for (final e in find.byType(RichText).evaluate()) {
              final ro = e.renderObject;
              if (ro is! RenderParagraph) continue;
              final s = ro.text.toPlainText();
              if (!counter.hasMatch(s)) continue;
              shown.add(s);
              // One line when the box is as wide as the text needs.
              final needed = ro.getMaxIntrinsicWidth(double.infinity);
              if (needed > ro.size.width + 0.5 || ro.didExceedMaxLines) {
                problems.add(
                  '${variantName(v)}: "$s" broken (box '
                  '${ro.size.width.toStringAsFixed(1)} < '
                  '${needed.toStringAsFixed(1)})',
                );
              }
            }
            if (shown.isEmpty) problems.add('${variantName(v)}: no counter');
            if (text.isNotEmpty && !shown.contains('1000/1000')) {
              problems.add('${variantName(v)}: full note counts $shown');
            }
          }
          t.view.resetViewInsets();
        });
        if (errors.isNotEmpty) {
          problems.add('${variantName(v)}: ${errors.toSet()}');
        }
        t.view.resetViewInsets();
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty);
    });
  });
}
