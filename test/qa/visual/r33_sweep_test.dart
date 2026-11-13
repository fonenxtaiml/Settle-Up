// QA VISUAL round 33: reverification of VISUAL-R31-02 (the app's own
// words cut with an ellipsis in rows), VISUAL-R32-01 (Settings switch
// label cut) and VISUAL-R32-02 (a row's text squeezed into a column
// narrower than a word) as classes, and repros for what the sweep found.
//
// The R32 repros pass now (r32_sweep_test.dart). KitListRow wraps the app's
// own words in full and BesideOrBelow keeps a row's text at least as wide
// as its widest word. The class is still open in places outside those
// two changes:
// - VISUAL-R31-02 (reopened): the Sync screen's nearby phone row keeps its
//   status line ("Wi-Fi, may share a group", "Bluetooth, shares Goa trip
//   and 2 more") capped as if it were user data;
// - VISUAL-R33-01: Settle up "What changes" keeps two fixed 96 dp columns
//   and leaves its labels a 34 dp column on a 320 dp phone;
// - VISUAL-R33-02: the Add expense Date tile breaks "Today," mid-word;
// - VISUAL-R33-03: the Description field label and the name hints are cut
//   at 2.0x.
// Every check walks the charter matrix (320x568 and 360x640, 1.0/1.3/2.0,
// light and dark) or the part of it named; r33_real_font_test.dart runs
// this file again with the bundled Familjen Grotesk.
//
// Tests named "QA VISUAL-R3x-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/list_section.dart';
import 'package:settle_up/ui/widgets/nearby.dart';
import 'package:settle_up/ui/widgets/settle_controls.dart';

import '../../ui/widgets/kit_harness.dart' show kitApp;
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

RenderParagraph _paragraph(WidgetTester t, Finder text) =>
    t.renderObject<RenderParagraph>(
      find.descendant(of: text.first, matching: find.byType(RichText)),
    );

void main() {
  configureVisualTests();

  // Regression around the VISUAL-R31-02 and VISUAL-R32-02 fixes: the
  // Settings rows (switch labels, values) and the Sync screen rows read
  // in full and never break a word over the charter matrix.
  testWidgets('R33 sweep: Settings and Sync rows read in full without '
      'breaking a word over the charter matrix', (t) async {
    late VisualPhone phone;
    await t.runAsync(() async => phone = await VisualPhone.create());
    final problems = <String>[];
    for (final v in kVariants) {
      for (final loc in [Routes.settings, Routes.sync]) {
        final at = '${variantName(v)} $loc';
        final errors = await collectLayoutErrors(() async {
          // A tall view: every row is built; widths match the phone.
          await pumpVisual(
            t,
            phone,
            v: (
              size: Size(v.size.width, 2400),
              scale: v.scale,
              brightness: v.brightness,
            ),
            location: loc,
          );
        });
        problems.addAll(errors.map((e) => '$at: $e'));
        for (final e in find.byType(RichText).evaluate()) {
          final p = e.renderObject;
          if (p is! RenderParagraph || !p.hasSize) continue;
          final text = p.text.toPlainText();
          // The phone's own name is user data, capped by design.
          if (p.didExceedMaxLines && !text.contains('Pixel')) {
            problems.add('$at: cut "$text"');
          }
          // The hotspot address and name are single tokens. The Sync
          // headline's "Everything" is 1 dp wider than the whole 280 dp
          // column at a linear 2.0x on 320 dp; Android 14+ scales a 24 sp
          // headline less than 2x (device check, not a finding).
          if (text.contains('192.168') ||
              text.contains('AndroidAP') ||
              text == S.everythingShared) {
            continue;
          }
          if (p.maxLines != 1) problems.addAll(_brokenWords(at, p));
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // VISUAL-R31-02 (reopened): NearbyPhoneRow (lib/ui/widgets/nearby.dart)
  // sets subtitleLines: 1 as if its status line were user data. The line
  // is the transport and the share status, the app's words ("Wi-Fi, may
  // share a group", "and 2 more") around at most one group name, and no
  // screen shows it in full. "Wi-Fi, may share a group" is cut at 2.0x on
  // 320 dp ("Wi-Fi, may share a ..."), and "Bluetooth, shares Goa trip
  // and 2 more" (an 8-character group name) at 1.3x and 2.0x on 320 and
  // 360 dp, losing "and 2 more".
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R31-02: the nearby phone row cuts its status line ("Wi-Fi, '
    'may share a group", "... and 2 more") with an ellipsis',
    (t) async {
      final problems = <String>[];
      for (final v in kVariants) {
        for (final (sub, action) in [
          ('Wi-Fi, may share a group', NearbyPhoneAction.sync),
          ('Bluetooth, no shared groups', NearbyPhoneAction.pair),
          ('Bluetooth, shares Goa trip and 2 more', NearbyPhoneAction.sync),
        ]) {
          setView(t, v.size);
          await t.pumpWidget(
            kitApp(
              Padding(
                // The sync screen's 16 dp gutter.
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ListSection(
                  children: [
                    NearbyPhoneRow(
                      name: "Priya's Pixel 8",
                      subtitle: sub,
                      action: action,
                      onAction: () {},
                    ),
                  ],
                ),
              ),
              brightness: v.brightness,
              textScale: v.scale,
            ),
          );
          await t.pumpAndSettle();
          if (_paragraph(t, find.text(sub)).didExceedMaxLines) {
            problems.add('${variantName(v)}: cut "$sub"');
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R33-01: BeforeAfterTable (lib/ui/widgets/settle_controls.dart)
  // keeps a 96 dp Now column, a 22 dp arrow and a 96 dp After column
  // below the large-text threshold, so on a 320 dp phone its labels get a
  // 34 dp column: "Kuwai/t Goa/trip", "Sam over/all", "All group/s",
  // "Your over/all" at 1.0x and 1.3x (rows up to 100 dp tall). On 360 dp
  // the column is 74 dp.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R33-01: Settle up "What changes" breaks its row labels '
    'mid-word in a 34 dp column on a 320 dp phone (1.0x and 1.3x)',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        await pumpVisual(t, w.phone, v: v, location: w.screens['settle KWD']);
        final table = find.byType(BeforeAfterTable);
        await t.scrollUntilVisible(
          table,
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await settleFrames(t);
        for (final e
            in find
                .descendant(of: table, matching: find.byType(RichText))
                .evaluate()) {
          final p = e.renderObject! as RenderParagraph;
          if (p.maxLines == 1) continue;
          problems.addAll(_brokenWords(at, p));
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R33-02: the Add expense Date tile (PickerTile beside Paid by)
  // takes the narrowest width that fits its value in 2 to 4 lines, and
  // that width may break a word: on a 320 dp phone at 1.3x "Today, 9 Nov"
  // shows as "Today / , 9 / Nov" in a 52 dp column ("Yesterday," and
  // weekday names are wider still).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R33-02: the Add expense Date tile breaks "Today," mid-word '
    'on a 320 dp phone at 1.3x',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in kVariants) {
        await pumpVisual(
          t,
          w.phone,
          v: (
            size: Size(v.size.width, 1400),
            scale: v.scale,
            brightness: v.brightness,
          ),
          location: w.screens['new expense'],
        );
        final f = find.textContaining('Today, ');
        if (f.evaluate().isEmpty) {
          problems.add('${variantName(v)}: date not shown');
        } else {
          problems.addAll(_brokenWords(variantName(v), _paragraph(t, f)));
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R33-03: LabeledTextField (lib/ui/widgets/form_tiles.dart)
  // floats its label in the room left by a trailing chip and keeps the
  // hint to one line: at 2.0x on a 320 dp phone the Add/Edit expense
  // label reads "Descripti..." beside the category chip, and the hints
  // read "For example, Goa..." (Edit group, 320 dp) and "For example,
  // Pri..." (Members > Add person, 320 and 360 dp).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R33-03: the Description field label and the name hints are '
    'cut with an ellipsis at 2.0x',
    skip: true, // QA VISUAL-R33-03: field label and hint cut at 2.0x
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in kVariants) {
        for (final (loc, text) in [
          (w.screens['new expense']!, S.description),
          (w.screens['edit group']!, S.groupNameHint),
          (w.screens['members']!, S.personNameHint),
        ]) {
          await pumpVisual(
            t,
            w.phone,
            v: (
              size: Size(v.size.width, 2400),
              scale: v.scale,
              brightness: v.brightness,
            ),
            location: loc,
          );
          final f = find.text(text);
          if (f.evaluate().isNotEmpty && _paragraph(t, f).didExceedMaxLines) {
            problems.add('${variantName(v)} $loc: cut "$text"');
          }
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
