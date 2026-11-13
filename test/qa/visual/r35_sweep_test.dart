// QA VISUAL round 35: reverification of VISUAL-R34-01 (an amount in a
// sentence split across lines), VISUAL-R34-02 (an entry's title cut in a
// one-line app bar and shown nowhere else) and VISUAL-R34-03 (a bare,
// stale amount on Edit payment) as classes, and a regression sweep around
// the changed widgets (FitWordsText in KitListRow sublines, button labels
// and heroes; AppBarTitle with TitleCutScope and CutTitleHeading).
// Every check walks the charter matrix (320x568 and 360x640, 1.0/1.3/2.0,
// light and dark) or the part of it named; r35_real_font_test.dart runs
// this file again with the bundled Familjen Grotesk.
//
// Tests named "QA VISUAL-R3x-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/app_chrome.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'visual_harness.dart';

/// Words of [p] wider than the column they are laid out in (so broken in
/// the middle), as one line each.
List<String> _brokenWords(String at, RenderParagraph p) {
  final out = <String>[];
  final span = p.text;
  final text = span.toPlainText();
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final tp = TextPainter(
      text: TextSpan(text: word, style: span.style),
      textScaler: p.textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final room = p.constraints.maxWidth;
    if (tp.width > room + 0.5) {
      out.add(
        '$at: "$word" of "$text" is ${tp.width.round()} dp wide in a '
        '${room.round()} dp column',
      );
    }
    tp.dispose();
  }
  return out;
}

/// Every amount word split across lines on screen.
List<String> _brokenAmounts(WidgetTester t, String at) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.hasSize && p.maxLines != 1)
      for (final b in _brokenWords(at, p))
        if (RegExp(r'\d').hasMatch(b.split('"')[1])) b,
];

Variant _tall(Variant v) =>
    (size: Size(v.size.width, 2400), scale: v.scale, brightness: v.brightness);

/// Whether [text] is shown somewhere on screen in full (never cut).
bool _shownInFull(WidgetTester t, String text) =>
    find.byType(RichText).evaluate().any((e) {
      final p = e.renderObject;
      return p is RenderParagraph &&
          p.hasSize &&
          p.text.toPlainText() == text &&
          !p.didExceedMaxLines;
    });

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R34-01 class (reopened): every sentence that carries an amount,
  // beyond the screens the round 34 repro walked. Members > Sam K > Remove
  // in the KWD group of the huge world opens "Sam K can't be removed yet"
  // whose body, "Sam K has KD99,999,999.999 open in this group. Settle up
  // first, then remove.", is a plain Text in the AlertDialog's content
  // (lib/ui/screens/group/members_screen.dart). On a 320 dp phone at 2.0x
  // the amount is 242 dp wide in a 224 dp column and is broken mid-amount.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R34-01: the "can\'t be removed yet" dialog splits '
    'Money.maxMinor in KWD across lines at 2.0x on a 320 dp phone',
    skip: true, // QA VISUAL-R34-01: amount split in the Remove dialog body
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.huge());
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        await pumpVisual(
          t,
          w.phone,
          v: v,
          location: Routes.members(w.kwdGroup),
        );
        await t.tap(find.text('Sam K').first);
        await settleFrames(t);
        await t.tap(find.text(S.remove).last);
        await settleFrames(t);
        if (find.byType(AlertDialog).evaluate().isEmpty) {
          problems.add('$at: no dialog');
        }
        problems.addAll(_brokenAmounts(t, at));
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // VISUAL-R34-01 class, the expense editor: Money.maxMinor in KWD typed
  // into Add expense, then every split method. No sentence or share line
  // breaks an amount, and nothing overflows.
  testWidgets('R35 sweep: Add expense with Money.maxMinor in KWD never '
      'splits an amount, in every split method', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.huge());
    final problems = <String>{};
    for (final v in kVariants) {
      if (v.brightness == Brightness.dark) continue; // same layout
      final at = variantName(v);
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(
          t,
          w.phone,
          v: _tall(v),
          location: Routes.newExpense(groupId: w.kwdGroup),
        );
        await t.enterText(find.byType(EditableText).first, '99999999.999');
        await settleFrames(t);
        problems.addAll(_brokenAmounts(t, '$at equal'));
        for (final m in [
          KitStrings.splitExact,
          KitStrings.splitPercent,
          KitStrings.splitShares,
          KitStrings.splitAdjust,
        ]) {
          await t.tap(find.text(m).first, warnIfMissed: false);
          await settleFrames(t);
          problems.addAll(_brokenAmounts(t, '$at $m'));
        }
      });
      problems.addAll(errors.map((e) => '$at: $e'));
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // VISUAL-R34-02 class (reopened): a title the one-line app bar cuts must
  // read in full on its screen. The Home row of a group still waiting for
  // its first sync caps the name to one line (titleLines: 1) and opens the
  // group screen's pending branch (lib/ui/screens/group/group_screen.dart,
  // AppBarTitle(pendingName ?? S.groups)), which has no TitleCutScope or
  // CutTitleHeading; its body is the static "Waiting for the group" empty
  // state. A 60-character name never reads in full anywhere, at every
  // charter size and text scale.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R34-02: a group waiting for its first sync shows its name '
    'only in the one-line app bar, cut',
    skip: true, // QA VISUAL-R34-02: pending group name cut in the app bar
    (t) async {
      late VisualWorld w;
      const pending = 'cccc0000-0000-7000-8000-000000000001';
      await t.runAsync(() async {
        w = await VisualWorld.realistic();
        await w.phone.ledger.registerJoinedGroup(
          pending,
          Uint8List(32),
          kGroup60,
        );
      });
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        await pumpVisual(
          t,
          w.phone,
          v: _tall(v),
          location: Routes.group(pending),
        );
        expect(find.byType(AppBarTitle), findsOneWidget);
        if (!_shownInFull(t, kGroup60)) {
          problems.add('$at: "$kGroup60" never shown in full');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R34-03 class: an amount TalkBack reads with nothing but the
  // amount ("₹200"), on any screen of the realistic world.
  // ------------------------------------------------------------------

  testWidgets('R35 sweep: no screen has a semantics node that is a bare '
      'amount', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final problems = <String>{};
    for (final v in kVariants) {
      if (v.brightness == Brightness.dark) continue;
      for (final MapEntry(key: name, value: loc) in {
        ...w.screens,
        'edit payment': Routes.editExpense(w.payment),
        'group activity': Routes.groupActivity(w.group),
      }.entries) {
        await pumpVisual(t, w.phone, v: _tall(v), location: loc);
        for (final l in semanticsLabels(t)) {
          if (kPureAmount.hasMatch(l.trim())) {
            problems.add('${variantName(v)} $name: bare "$l"');
          }
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // Every titled screen with the longest names: the title reads in full
  // once, and the body heading is absent when the app bar fits it.
  testWidgets('R35 sweep: group, person and detail titles read in full at '
      'every charter size; no heading repeats a title that fits', (t) async {
    late VisualWorld long, real;
    await t.runAsync(() async {
      long = await VisualWorld.longNames();
      real = await VisualWorld.realistic();
    });
    final problems = <String>[];
    for (final v in kVariants) {
      for (final (w, name, text) in [
        (long, 'group', kGroup60),
        (long, 'person', kName40),
        (long, 'expense', kDesc120),
        (long, 'payment', 'Sam paid Bartholomew'),
        (real, 'group', 'Goa trip'),
      ]) {
        final at = '${variantName(v)} $name';
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, w.phone, v: _tall(v), location: w.screens[name]),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        if (!_shownInFull(t, text)) problems.add('$at: "$text" cut');
        if (w == real &&
            find.byType(CutTitleHeading).evaluate().isNotEmpty &&
            find.text(text).evaluate().length > 1) {
          problems.add('$at: "$text" shown twice');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() async {
      await long.phone.dispose();
      await real.phone.dispose();
    });
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
