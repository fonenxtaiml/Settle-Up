// QA VISUAL round 32: reverification of VISUAL-R31-01 (field helper and
// error text cut) and VISUAL-R31-02 (notice row text cut) as classes.
//
// VISUAL-R31-01 is checked by the R31 dialog sweeps (field text included
// since the fix) and here by the screens' own fields. VISUAL-R31-02 was
// fixed for the Settings clock notice and the sync radio rows
// (KitListRow.fullText), but the other rows that carry a notice, a help
// line or an empty state's only instruction still hold their text to one
// line (three at a large text size) with an ellipsis; that is the reopened
// repro below. Every check walks the charter matrix (320x568 and 360x640,
// 1.0/1.3/2.0, light and dark); r32_real_font_test.dart runs this file
// again with the bundled Familjen Grotesk.
//
// Tests named "QA VISUAL-R3x-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/sync/radios.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../ui/widgets/kit_harness.dart' show kitApp;
import 'visual_harness.dart';

/// One text to read in full on a screen.
typedef _Target = ({
  String name,
  String location,
  String text,
  Future<void> Function(WidgetTester t)? then,
});

/// Opens each target over [kVariants], scrolls its text into view and
/// returns one line per text that is not shown, cut, or laid out wrong.
Future<List<String>> _readInFull(
  WidgetTester t,
  VisualPhone phone,
  List<_Target> targets,
) async {
  final problems = <String>[];
  for (final v in kVariants) {
    for (final x in targets) {
      final at = '${variantName(v)} ${x.name}';
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, phone, v: v, location: x.location);
        if (x.then != null) await x.then!(t);
        final f = find.text(x.text);
        if (f.evaluate().isEmpty &&
            find.byType(Scrollable).evaluate().isNotEmpty) {
          try {
            await t.scrollUntilVisible(
              f,
              100,
              scrollable: find.byType(Scrollable).first,
              maxScrolls: 40,
            );
          } on StateError {
            // Not on the screen at all: reported below.
          }
          await settleFrames(t);
        }
      });
      for (final e in errors) {
        problems.add('$at: $e');
      }
      final f = find.text(x.text);
      if (f.evaluate().isEmpty) {
        problems.add('$at: "${x.text}" not shown');
      } else {
        final p = t.renderObject<RenderParagraph>(
          find.descendant(of: f.first, matching: find.byType(RichText)),
        );
        if (p.didExceedMaxLines) problems.add('$at: cut "${x.text}"');
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
  }
  return problems;
}

void main() {
  configureVisualTests();

  // VISUAL-R31-01 (fixed): the screens' own fields show their error text
  // in full over the charter matrix: a group name with no letter or
  // number.
  testWidgets('R32 sweep: a field error on Edit group reads '
      'in full over the charter matrix', (t) async {
    late VisualPhone phone;
    late String g;
    await t.runAsync(() async {
      phone = await VisualPhone.create();
      g = (await phone.group('Goa trip', ['Priya'])).g;
    });
    Future<void> Function(WidgetTester) type(
      String hint, {
      bool last = false,
    }) => (t) async {
      await t.scrollUntilVisible(
        find.text(hint),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      final fields = find.byType(TextField);
      await t.enterText(last ? fields.last : fields.first, '!!!');
      await settleFrames(t);
    };
    final problems = await _readInFull(t, phone, [
      (
        name: 'edit group name',
        location: Routes.editGroup(g),
        text: S.nameNeedsLetter,
        then: type(S.groupNameHint),
      ),
    ]);
    await t.runAsync(phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // Regression around the VISUAL-R31-02 fix: the sync radio rows now
  // show their text in full and put their button under the help at a
  // large text size. Every row keeps a 48 dp labeled button on screen and
  // no overflow; contrast holds except where VISUAL-R32-02 squeezes the
  // text (repro below).
  testWidgets('R32 sweep: the sync radio rows keep their buttons and '
      'labels over the charter matrix', (t) async {
    expect(await _radioCard(t, repro: false), isEmpty);
  });

  // ------------------------------------------------------------------
  // VISUAL-R32-02: below the large-text threshold a sync radio row keeps
  // its button beside the text (keepTrailingBeside), and since the
  // VISUAL-R31-02 fix its title and help wrap in full. On a 320 dp phone
  // at 1.3x the button leaves the text a 32 to 65 dp column: words break
  // in the middle ("Blu/eto/oth is off", "Tur/n it on"), a row is up to
  // 500 dp tall, and textContrastGuideline fails on the help. At 1.0x on
  // 320 dp "Bluetooth" (68 dp) already breaks in a 65 dp column.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R32-02: the sync radio rows squeeze their title and help '
    'into a column too narrow for a word on a 320 dp phone (1.0x and 1.3x)',
    (t) async {
      final problems = await _radioCard(t, repro: true);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R31-02 (reopened): the fix gave KitListRow a fullText mode and
  // used it for the clock notice and the sync radio rows only. The other
  // notice, help and empty-state rows still cut their text:
  // - Sync with no phone nearby: "Ask your friend to open Sync and turn
  //   on Make this phone visible." (the empty state's only instruction)
  //   at 1.0x and 1.3x on 320 and 360 dp phones;
  // - Group with nothing owed: "No payments needed. New expenses show up
  //   here." at 1.0x and 1.3x (and 2.0x on 320 dp);
  // - Members: "Friends scan it with Settle Up to join and sync." at 1.0x
  //   and 1.3x, and its title "Invite with a QR code" at 1.3x on 320 dp;
  // - Edit group: the Simplify debts help, "Showing who owes whom from
  //   each expense." at 1.0x and 1.3x on 320 and 360 dp phones and "Fewer
  //   payments, same totals." at 1.3x on 320 dp;
  // - Home sync strip: "Not synced with another phone yet" at 1.0x and
  //   1.3x on 320 and 360 dp phones.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R31-02: notice, help and empty-state rows other than the '
    'clock notice still cut their text with an ellipsis (Sync empty state, '
    'Everyone is settled up, Invite with a QR code, Simplify debts help, '
    'Home "Not synced" line)',
    (t) async {
      late VisualPhone phone;
      late String g;
      await t.runAsync(() async {
        phone = await VisualPhone.create();
        g = (await phone.group('Goa trip', ['Priya'])).g;
      });
      Future<void> toggleSimplify(WidgetTester t) async {
        final s = find.text(S.simplifyDebts);
        await t.scrollUntilVisible(
          s,
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await t.ensureVisible(s.first);
        await settleFrames(t);
        await t.tap(s.first);
        await settleFrames(t);
      }

      final problems = await _readInFull(t, phone, [
        (
          name: 'sync empty',
          location: Routes.sync,
          text: S.noneNearbyBody,
          then: null,
        ),
        (
          name: 'group settled',
          location: Routes.group(g),
          text: S.everyoneSettledBody,
          then: null,
        ),
        (
          name: 'members invite',
          location: Routes.members(g),
          text: S.inviteByQr,
          then: null,
        ),
        (
          name: 'members invite help',
          location: Routes.members(g),
          text: S.inviteByQrBody,
          then: null,
        ),
        (
          name: 'edit group simplify on',
          location: Routes.editGroup(g),
          text: S.simplifyHelpOn,
          then: null,
        ),
        (
          name: 'edit group simplify off',
          location: Routes.editGroup(g),
          text: S.simplifyHelpOff,
          then: toggleSimplify,
        ),
        (
          name: 'home never synced',
          location: Routes.home,
          text: KitStrings.neverSynced,
          then: null,
        ),
      ]);
      await t.runAsync(phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R32-01: a Settings switch row holds its label to one line
  // below the large-text threshold, so "Simplify debts in new groups"
  // reads "Simplify debts in new gro..." at 1.0x on a 320 dp phone and at
  // 1.3x on 360 dp. The label is the only text that says what the switch
  // does, and no screen shows it in full.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R32-01: the Settings switch label "Simplify debts in new '
    'groups" is cut with an ellipsis at 1.0x on 320 dp and 1.3x on 360 dp',
    skip: true, // QA VISUAL-R32-01: Settings switch label cut
    (t) async {
      late VisualPhone phone;
      await t.runAsync(() async => phone = await VisualPhone.create());
      final problems = await _readInFull(t, phone, [
        (
          name: 'settings simplify',
          location: Routes.settings,
          text: S.simplifyNewGroups,
          then: null,
        ),
        (
          name: 'settings vibration',
          location: Routes.settings,
          text: S.vibration,
          then: null,
        ),
      ]);
      await t.runAsync(phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}

/// The sync radio card with every issue over [kVariants]. Always checks
/// layout errors, 48 dp labeled buttons and that each button lies on
/// screen, and contrast outside 320 dp @1.3x; with [repro] also words cut
/// in the middle by a narrow text column and contrast everywhere
/// (VISUAL-R32-02).
Future<List<String>> _radioCard(WidgetTester t, {required bool repro}) async {
  final handle = t.ensureSemantics();
  final problems = <String>[];
  for (final v in kVariants) {
    final at = variantName(v);
    setView(t, v.size);
    final errors = await collectLayoutErrors(() async {
      await t.pumpWidget(
        kitApp(
          Padding(
            // The sync screen's 16 dp gutter.
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: RadioIssuesCard(issues: RadioIssue.values, onAllow: () {}),
          ),
          brightness: v.brightness,
          textScale: v.scale,
        ),
      );
      await t.pumpAndSettle();
    });
    for (final e in errors) {
      problems.add('$at: $e');
    }
    final buttons = find.byWidgetPredicate((w) => w is ButtonStyleButton);
    if (buttons.evaluate().length != RadioIssue.values.length) {
      problems.add('$at: ${buttons.evaluate().length} buttons');
    }
    for (final b in buttons.evaluate()) {
      final r = t.getRect(find.byWidget(b.widget));
      if (r.left < 0 || r.right > v.size.width + 0.5) {
        problems.add('$at: button at ${r.left.round()}-${r.right.round()}');
      }
    }
    final squeezed = v.size.width == 320 && v.scale == 1.3;
    for (final (name, g) in [
      ('androidTapTargetGuideline', androidTapTargetGuideline),
      ('labeledTapTargetGuideline', labeledTapTargetGuideline),
    ]) {
      final res = await g.evaluate(t);
      if (!res.passed) problems.add('$at $name: ${res.reason}');
    }
    if (repro || !squeezed) {
      // Contrast with the whole card on screen: a paragraph cut by the
      // viewport's bottom edge has its inflated paint rect sampled over
      // the scaffold under the clip, and the guideline then reports that
      // grey against the card's white (1.14) instead of the text's ink.
      final card = t.getRect(find.byType(RadioIssuesCard));
      if (card.bottom > v.size.height - 16) {
        setView(t, Size(v.size.width, card.bottom + 64));
        await t.pumpAndSettle();
      }
      final res = await textContrastGuideline.evaluate(t);
      if (!res.passed) problems.add('$at textContrastGuideline: ${res.reason}');
    }
    if (repro) {
      for (final e
          in find
              .descendant(
                of: find.byType(RadioIssuesCard),
                matching: find.byType(RichText),
              )
              .evaluate()) {
        final p = e.renderObject! as RenderParagraph;
        final span = p.text;
        if (span is! TextSpan) continue;
        for (final word in span.toPlainText().split(RegExp(r'\s+'))) {
          if (word.isEmpty) continue;
          final tp = TextPainter(
            text: TextSpan(text: word, style: span.style),
            textScaler: p.textScaler,
            textDirection: TextDirection.ltr,
          )..layout();
          final room = p.constraints.maxWidth;
          if (tp.width > room + 0.5) {
            problems.add(
              '$at: "$word" is ${tp.width.round()} dp wide in a '
              '${room.round()} dp column',
            );
          }
          tp.dispose();
        }
      }
    }
    await t.pumpWidget(const SizedBox.shrink());
  }
  handle.dispose();
  return problems;
}
