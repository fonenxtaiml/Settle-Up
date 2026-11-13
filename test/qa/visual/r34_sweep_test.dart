// QA VISUAL round 34: reverification of VISUAL-R31-02 (the app's own
// words cut with an ellipsis in rows), VISUAL-R33-01 (Settle up "What
// changes" labels broken mid-word), VISUAL-R33-02 (the Date tile value
// broken mid-word) and VISUAL-R33-03 (field label and hints cut) as
// classes, a regression sweep around the changed widgets (LabeledTextField,
// PickerTile and PickerTilePair, KeyValueRow, BeforeAfterTable,
// NearbyPhoneRow), and repros for what the sweep found:
// - VISUAL-R34-01: Money.maxMinor in KWD breaks mid-amount at 2.0x on a
//   320 dp phone ("Sam paid / KD99,999,999.99 / 9", "Record KD99,999, /
//   999.999 payment");
// - VISUAL-R34-02: the expense and payment detail screens show the entry's
//   title (its description, or who paid whom) only in the one-line app bar
//   title, cut with an ellipsis ("Dinner at ...", "Sam paid ...").
// Every check walks the charter matrix (320x568 and 360x640, 1.0/1.3/2.0,
// light and dark) or the part of it named; r34_real_font_test.dart runs
// this file again with the bundled Familjen Grotesk.
//
// Tests named "QA VISUAL-R3x-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/form_tiles.dart';

import 'visual_harness.dart';

/// Words of [p] wider than the column they are laid out in (so broken in
/// the middle), as one line each.
List<String> _brokenWords(String at, RenderParagraph p) {
  final out = <String>[];
  final span = p.text;
  if (span is! TextSpan) return out;
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

/// The charter matrix with a tall view: every row is built, widths match
/// the phone.
Variant _tall(Variant v) =>
    (size: Size(v.size.width, 2400), scale: v.scale, brightness: v.brightness);

/// Every screen of [w], the round 34 additions included.
Map<String, String> _allScreens(VisualWorld w) => {
  ...w.screens,
  'new group': Routes.newGroup,
  'sync host': Routes.syncHost,
  'sync scan': Routes.syncScan,
  'group activity': Routes.groupActivity(w.group),
  'claim': Routes.claim(w.group),
  'edit payment': Routes.editExpense(w.payment),
  'new expense person': Routes.newExpense(personId: w.person),
  'new expense KWD': Routes.newExpense(groupId: w.kwdGroup),
};

/// Single tokens wider than any column a phone has for them: the hotspot
/// address and name, and an 18-letter surname at 2.0x. The VISUAL-R34-01
/// amount is no longer one: an amount is never split across lines.
bool _unbreakable(String word) =>
    word.contains('192.168') ||
    word.contains('AndroidAP') ||
    word == 'Fitzgerald-Johnsto';

/// The paragraph of a [find.text] match.
RenderParagraph? _paragraphOf(WidgetTester t, Element e) {
  final ro = find
      .descendant(
        of: find.byElementPredicate((x) => x == e),
        matching: find.byType(RichText),
      )
      .evaluate()
      .firstOrNull
      ?.renderObject;
  return ro is RenderParagraph ? ro : null;
}

void main() {
  configureVisualTests();

  // Regression around every round 33 change: no screen overflows, cuts an
  // amount or breaks a word of a wrapping paragraph, in the realistic,
  // longest-name and Money.maxMinor worlds.
  for (final world in ['realistic', 'long names', 'huge']) {
    testWidgets('R34 sweep ($world): every screen lays out without '
        'overflow, cut amounts or words broken mid-word', (t) async {
      late VisualWorld w;
      await t.runAsync(
        () async => w = switch (world) {
          'realistic' => await VisualWorld.realistic(),
          'long names' => await VisualWorld.longNames(),
          _ => await VisualWorld.huge(),
        },
      );
      final problems = <String>{};
      for (final v in kVariants) {
        if (v.brightness == Brightness.dark) continue; // same layout
        for (final MapEntry(key: name, value: loc) in _allScreens(w).entries) {
          final at = '${variantName(v)} $name';
          final errors = await collectLayoutErrors(
            () => pumpVisual(t, w.phone, v: _tall(v), location: loc),
          );
          problems.addAll(errors.map((e) => '$at: $e'));
          problems.addAll(findCutAmounts(t).map((c) => '$at: $c'));
          for (final e in find.byType(RichText).evaluate()) {
            final p = e.renderObject;
            if (p is! RenderParagraph || !p.hasSize || p.maxLines == 1) {
              continue;
            }
            for (final b in _brokenWords(at, p)) {
              if (!_unbreakable(b.split('"')[1])) problems.add(b);
            }
          }
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  // Onboarding (a name field and the currency PickerTile) over the matrix.
  testWidgets('R34 sweep: onboarding reads in full without breaking a word', (
    t,
  ) async {
    late VisualPhone p;
    await t.runAsync(() async => p = await VisualPhone.create(onboard: false));
    final problems = <String>[];
    for (final v in kVariants) {
      final at = '${variantName(v)} onboarding';
      final errors = await collectLayoutErrors(
        () => pumpVisual(t, p, v: _tall(v), location: Routes.onboarding),
      );
      problems.addAll(errors.map((e) => '$at: $e'));
      for (final e in find.byType(RichText).evaluate()) {
        final r = e.renderObject;
        if (r is! RenderParagraph || !r.hasSize) continue;
        if (r.didExceedMaxLines) {
          problems.add('$at: cut "${r.text.toPlainText()}"');
        }
        if (r.maxLines != 1) problems.addAll(_brokenWords(at, r));
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(p.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // VISUAL-R33-03 regression: the label now sits in the field's top
  // padding instead of InputDecoration.labelText. It must never overlap
  // what the user types or the hint, the whole field keeps a 48 dp tap,
  // and TalkBack still reads the label on the text field.
  testWidgets('R34 sweep: a labelled field never draws its label over the '
      'input or the hint, and reads the label on the text field', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.longNames());
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final v in kVariants) {
      for (final MapEntry(key: name, value: loc) in {
        'new expense': w.screens['new expense']!,
        'edit expense': w.screens['edit expense']!,
        'edit group': w.screens['edit group']!,
        'members': w.screens['members']!,
        'edit payment': Routes.editExpense(w.payment),
        'sync scan': Routes.syncScan,
      }.entries) {
        final at = '${variantName(v)} $name';
        await pumpVisual(t, w.phone, v: _tall(v), location: loc);
        final fields = find.byType(LabeledTextField);
        if (fields.evaluate().isEmpty) {
          problems.add('$at: no labelled field');
        }
        for (final f in fields.evaluate()) {
          final field = f.widget as LabeledTextField;
          final label = find.descendant(
            of: find.byElementPredicate((x) => x == f),
            matching: find.text(field.label),
          );
          final editable = find.descendant(
            of: find.byElementPredicate((x) => x == f),
            matching: find.byType(EditableText),
          );
          if (label.evaluate().isEmpty || editable.evaluate().isEmpty) {
            problems.add('$at: "${field.label}" not shown');
            continue;
          }
          final l = t.getRect(label);
          final ed = t.getRect(editable);
          if (l.bottom > ed.top + 0.5) {
            problems.add(
              '$at: "${field.label}" label bottom ${l.bottom.round()} '
              'over the input top ${ed.top.round()}',
            );
          }
          if (field.hintText case final hint?) {
            final h = find.descendant(
              of: find.byElementPredicate((x) => x == f),
              matching: find.text(hint),
            );
            for (final he in h.evaluate()) {
              final hr = t.getRect(find.byElementPredicate((x) => x == he));
              if (hr.top < l.bottom - 0.5) {
                problems.add('$at: hint "$hint" under the label');
              }
              final p = _paragraphOf(t, he);
              if (p != null && p.didExceedMaxLines) {
                problems.add('$at: hint "$hint" cut');
              }
            }
          }
          final box = t.getRect(find.byElementPredicate((x) => x == f));
          if (box.height < 48) problems.add('$at: "${field.label}" < 48 dp');
          final node = t.getSemantics(
            find.descendant(
              of: find.byElementPredicate((x) => x == f),
              matching: find.byType(TextField),
            ),
          );
          if (!node.label.contains(field.label)) {
            problems.add('$at: TalkBack label "${node.label}"');
          }
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // The changed screens meet the tap target, labelled target and contrast
  // guidelines in both themes over the charter matrix.
  testWidgets('R34 sweep: the changed screens meet the 48 dp, labelled '
      'target and text contrast guidelines in both themes', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final v in kVariants) {
      for (final MapEntry(key: name, value: loc) in {
        'new expense': w.screens['new expense']!,
        'edit group': w.screens['edit group']!,
        'members': w.screens['members']!,
        'settle KWD': w.screens['settle KWD']!,
        'edit payment': Routes.editExpense(w.payment),
      }.entries) {
        final at = '${variantName(v)} $name';
        // A tall view: text half under the bottom bar (the split chips at
        // 360 dp, 1.3x) would sample the bar's colour, not a defect.
        await pumpVisual(t, w.phone, v: _tall(v), location: loc);
        for (final (gname, g) in [
          ('tap target', androidTapTargetGuideline),
          ('labelled', labeledTapTargetGuideline),
          // Edit payment included: the bare "₹200" line the guideline
          // used to sample (VISUAL-R34-03) is gone.
          ('contrast', textContrastGuideline),
        ]) {
          final r = await g.evaluate(t);
          if (!r.passed) problems.add('$at $gname: ${r.reason}');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // VISUAL-R34-01: an amount in a sentence wraps like any word, so
  // Money.maxMinor in KWD (KD99,999,999.999, about 209 dp at 2.0x) breaks
  // mid-amount when it is wider than its line. On a 320 dp phone at 2.0x,
  // light and dark: the KWD group's expense row subline shows "Sam paid /
  // KD99,999,999.99 / 9" in a 202 dp column, and the Settle up button
  // shows "Record KD99,999, / 999.999 payment" in a 244 dp label. The
  // first line reads as a whole, different amount.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R34-01: Money.maxMinor in KWD breaks mid-amount at 2.0x on '
    'a 320 dp phone ("KD99,999,999.99 / 9", "KD99,999, / 999.999")',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.huge());
      final problems = <String>[];
      for (final v in kVariants) {
        for (final loc in ['group KWD', 'settle KWD', 'home', 'person']) {
          final at = '${variantName(v)} $loc';
          await pumpVisual(t, w.phone, v: _tall(v), location: w.screens[loc]);
          for (final e in find.byType(RichText).evaluate()) {
            final p = e.renderObject;
            if (p is! RenderParagraph || !p.hasSize || p.maxLines == 1) {
              continue;
            }
            for (final b in _brokenWords(at, p)) {
              if (b.split('"')[1].contains('KD99,999,999.999')) {
                problems.add(b);
              }
            }
          }
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R34-02: rows cap a description or a payment's names to one line
  // because the entry reads in full one tap away (KitListRow). That tap
  // opens the expense detail screen, which shows the entry's title only in
  // the app bar (AppBarTitle: maxLines 1, ellipsis) and nowhere in the
  // body. A payment's receiver appears nowhere else on its screen.
  // "Dinner at the shack" reads "Dinner at ..." at 1.0x on 320 dp and at
  // 1.3x on 360 dp; "Sam paid Priya" reads "Sam paid ..." at 1.3x and 2.0x
  // on 320 dp; the 120-character description never reads in full.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R34-02: the expense and payment detail screens cut the '
    "entry's title (\"Dinner at ...\", \"Sam paid ...\") in a one-line app "
    'bar and show it nowhere else',
    (t) async {
      late VisualWorld real, long;
      await t.runAsync(() async {
        real = await VisualWorld.realistic();
        long = await VisualWorld.longNames();
      });
      final problems = <String>[];
      for (final v in kVariants) {
        for (final (w, loc, text) in [
          (real, real.screens['expense']!, 'Dinner at the shack'),
          (real, real.screens['payment']!, 'Sam paid Priya'),
          (long, long.screens['expense']!, kDesc120),
        ]) {
          final at = '${variantName(v)} $loc';
          await pumpVisual(t, w.phone, v: _tall(v), location: loc);
          final shown = find.text(text).evaluate().any((e) {
            final p = _paragraphOf(t, e);
            return p != null && !p.didExceedMaxLines;
          });
          if (!shown) problems.add('$at: "$text" never shown in full');
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
      await t.runAsync(() async {
        await real.phone.dispose();
        await long.phone.dispose();
      });
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R34-03: Edit payment (lib/ui/screens/expense/payment_edit.dart,
  // the textGutter after the Note field) shows a bare "₹200" in small
  // body text: no label and no direction word, and TalkBack reads only
  // "₹200". It is the stored total, so after the user types a new amount
  // (350) the screen shows ₹350 in the amount field and still "₹200"
  // under Note. Every charter size and text scale, light and dark.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R34-03: Edit payment shows a bare, unlabelled "₹200" under '
    'Note that keeps the stored amount after the user changes it',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        await pumpVisual(
          t,
          w.phone,
          v: _tall(v),
          location: Routes.editExpense(w.payment),
        );
        await t.enterText(find.byType(EditableText).first, '350');
        await settleFrames(t);
        final bare = visibleTexts(t).where((s) => s.trim() == '₹200');
        if (bare.isNotEmpty) {
          problems.add('$at: bare "₹200" shown after the amount became 350');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
