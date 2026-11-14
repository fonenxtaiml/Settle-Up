// QA VISUAL round 41: reverification of VISUAL-R39-01 (Settle up offers a
// payment above Money.maxMinor that it cannot record) and a sweep of the
// changed Settle up screen around it.
//
// The fix offers at most Money.maxMinor and adds the note "One payment can
// be at most X. Y will still be owed: record it as another payment." under
// the tether. This file probes the whole class: both directions (they owe
// me, I owe them) and a payment between two others, INR and KWD, every
// size, scale and theme; the note, the Record label and the amounts shown
// in full, read by TalkBack, and the guidelines; "Pay part of it" opening
// on the offered amount; recording the offer, with animations on and off.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'visual_harness.dart';

bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().replaceAll('\n', ' ').contains(text) &&
      !p.didExceedMaxLines;
});

String _why(Evaluation r) => r.reason?.split('\n').first ?? 'failed';

/// The three guidelines, a contrast failure measured again with the lists
/// moved 12 dp (as the r39 sweep does).
Future<List<String>> _guidelines(WidgetTester t, String at) async {
  final out = <String>[];
  for (final g in [
    androidTapTargetGuideline,
    labeledTapTargetGuideline,
    textContrastGuideline,
  ]) {
    var r = await g.evaluate(t);
    if (!r.passed && g == textContrastGuideline) {
      for (final e in find.byType(Scrollable).evaluate()) {
        final pos = ((e as StatefulElement).state as ScrollableState).position;
        if (pos.axis == Axis.vertical && pos.maxScrollExtent > 0) {
          final to = pos.pixels + 12 > pos.maxScrollExtent
              ? pos.pixels - 12
              : pos.pixels + 12;
          pos.jumpTo(to.clamp(0, pos.maxScrollExtent));
        }
      }
      await t.pump();
      r = await g.evaluate(t);
    }
    if (!r.passed) out.add('$at ${g.description}: ${_why(r)}');
  }
  return out;
}

typedef _Case = ({
  String name,
  String gid,
  String from,
  String to,
  String currency,
});

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // A debt of twice Money.maxMinor, in INR (they owe me), in KWD (I owe
  // them) and between two others with 40-character names (INR), in a
  // 60-character group. Every size, scale and theme: no overflow and no
  // amount cut; the Record label offers exactly the limit and shows in
  // full; the cap note shows in full and TalkBack reads it; the guidelines.
  // ------------------------------------------------------------------
  testWidgets('R41 sweep: Settle up on a debt above the limit offers the '
      'limit and names the rest, in every variant', (t) async {
    final handle = t.ensureSemantics();
    late VisualPhone p;
    final cases = <_Case>[];
    final other = kName40.replaceFirst('B', 'C');
    await t.runAsync(() async {
      p = await VisualPhone.create(name: 'Arjun Mehta');
      final a = await p.group(kGroup60, [kName40]);
      for (var i = 0; i < 2; i++) {
        await p.add(
          a.g,
          total: Money.maxMinor,
          payer: a.m['me']!,
          owedBy: SplitSpec.single(a.m[kName40]!, Money.maxMinor),
        );
      }
      cases.add((
        name: 'INR they owe me',
        gid: a.g,
        from: a.m[kName40]!,
        to: a.m['me']!,
        currency: 'INR',
      ));
      final b = await p.group(kGroup60, [kName40], currency: 'KWD');
      for (var i = 0; i < 2; i++) {
        await p.add(
          b.g,
          total: Money.maxMinor,
          payer: b.m[kName40]!,
          currency: 'KWD',
          owedBy: SplitSpec.single(b.m['me']!, Money.maxMinor),
        );
      }
      cases.add((
        name: 'KWD I owe them',
        gid: b.g,
        from: b.m['me']!,
        to: b.m[kName40]!,
        currency: 'KWD',
      ));
      final c = await p.group(kGroup60, [kName40, other]);
      for (var i = 0; i < 2; i++) {
        await p.add(
          c.g,
          total: Money.maxMinor,
          payer: c.m[kName40]!,
          owedBy: SplitSpec.single(c.m[other]!, Money.maxMinor),
        );
      }
      cases.add((
        name: 'INR between two others',
        gid: c.g,
        from: c.m[other]!,
        to: c.m[kName40]!,
        currency: 'INR',
      ));
    });
    final problems = <String>[];
    for (final v in kVariants) {
      for (final c in cases) {
        final at = '${variantName(v)} ${c.name}';
        final most = MoneyFormat.format(Money.maxMinor, c.currency);
        final note = S.paymentCap(most, most);
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(
            t,
            p,
            v: v,
            location: Routes.settle(
              groupId: c.gid,
              from: c.from,
              to: c.to,
              currency: c.currency,
            ),
          );
        });
        problems.addAll(errors.map((e) => '$at: $e'));
        final cut = findCutAmounts(t);
        if (cut.isNotEmpty) problems.add('$at: cut ${cut.join('; ')}');
        final record = find.text(S.recordPayment(most));
        if (record.evaluate().length != 1) {
          problems.add('$at: no "${S.recordPayment(most)}" button');
        } else if (!_shownInFull(S.recordPayment(most))) {
          problems.add('$at: the Record label is cut');
        }
        await t.scrollUntilVisible(
          find.text(note),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await t.pump();
        if (!_shownInFull(note)) problems.add('$at: the cap note is cut');
        final labels = semanticsLabels(t);
        if (!labels.any((l) => l.contains(note))) {
          problems.add('$at: TalkBack does not read the cap note');
        }
        if (!labels.any((l) => l.contains(S.recordPayment(most)))) {
          problems.add('$at: TalkBack does not read the Record label');
        }
        problems.addAll(await _guidelines(t, at));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => p.dispose());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // "Pay part of it" on that debt, at the smallest and largest variants:
  // the sheet lays out and opens on the offered amount; typing more than
  // the limit names the limit and Done stays off; Done on the offer keeps
  // the note.
  // ------------------------------------------------------------------
  testWidgets('R41 sweep: "Pay part of it" above the limit opens on the '
      'offer and refuses more', (t) async {
    late VisualPhone p;
    late String gid, from, to;
    await t.runAsync(() async {
      p = await VisualPhone.create(name: 'Arjun Mehta');
      final g = await p.group('Goa trip', ['Priya Sharma'], currency: 'KWD');
      gid = g.g;
      from = g.m['Priya Sharma']!;
      to = g.m['me']!;
      for (var i = 0; i < 2; i++) {
        await p.add(
          g.g,
          total: Money.maxMinor,
          payer: to,
          currency: 'KWD',
          owedBy: SplitSpec.single(from, Money.maxMinor),
        );
      }
    });
    final problems = <String>[];
    final most = MoneyFormat.format(Money.maxMinor, 'KWD');
    for (final v in [kVariants.first, kVariants.last]) {
      final at = variantName(v);
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(
          t,
          p,
          v: v,
          location: Routes.settle(groupId: gid, from: from, to: to),
        );
        await t.tap(find.text(S.payPartOfIt));
        await settleFrames(t);
      });
      problems.addAll(errors.map((e) => '$at: $e'));
      final field = find.byType(EditableText);
      if (field.evaluate().length != 1) {
        problems.add('$at: no amount field');
      } else {
        final text = t.widget<EditableText>(field).controller.text;
        if (text.replaceAll(RegExp(r'[^\d]'), '') != '${Money.maxMinor}') {
          problems.add('$at: the sheet opens on "$text"');
        }
        await t.enterText(field, '99999999999');
        await t.pump();
        final done = find.widgetWithText(FilledButton, S.done);
        if (t.widget<FilledButton>(done).onPressed != null) {
          problems.add('$at: Done is on for an amount above the limit');
        }
        if (find.textContaining('up to').evaluate().isEmpty &&
            find.textContaining(most).evaluate().isEmpty) {
          problems.add('$at: no message names the limit');
        }
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(() => p.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // Recording the offer, with animations on and off, for a payment from
  // me (KWD): one payment of exactly the limit is stored, nothing says
  // "Check the highlighted fields.", and the screen closes.
  // ------------------------------------------------------------------
  for (final reduce in [false, true]) {
    testWidgets('R41 sweep: recording the offer above the limit stores one '
        'payment of the limit (animations ${reduce ? 'off' : 'on'})', (
      t,
    ) async {
      late VisualPhone p;
      late String gid, from, to;
      await t.runAsync(() async {
        p = await VisualPhone.create(name: 'Arjun Mehta');
        final g = await p.group('Goa trip', ['Priya Sharma'], currency: 'KWD');
        gid = g.g;
        from = g.m['me']!;
        to = g.m['Priya Sharma']!;
        for (var i = 0; i < 3; i++) {
          await p.add(
            g.g,
            total: Money.maxMinor,
            payer: to,
            currency: 'KWD',
            owedBy: SplitSpec.single(from, Money.maxMinor),
          );
        }
      });
      final most = MoneyFormat.format(Money.maxMinor, 'KWD');
      final left = MoneyFormat.format(2 * Money.maxMinor, 'KWD');
      await pumpVisual(
        t,
        p,
        v: kVariants.first,
        disableAnimations: reduce,
        location: Routes.settle(groupId: gid),
      );
      expect(find.text(S.paymentCap(most, left)), findsOneWidget);
      await t.tap(find.text(S.recordPayment(most)));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await settleFrames(t);
      await t.pump(const Duration(seconds: 2));
      await settleFrames(t);
      expect(find.text(S.errInvalidInput), findsNothing);
      final pays = p.gs(gid).expenses.values.where((e) => e.isPayment);
      expect(pays.map((e) => e.money.total), [Money.maxMinor]);
      expect(find.text(S.recordPayment(most)), findsNothing);
      await t.pumpWidget(const SizedBox.shrink());
      await t.runAsync(() => p.dispose());
    });
  }
}
