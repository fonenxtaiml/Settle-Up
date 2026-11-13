// QA VISUAL round 36: reverification of VISUAL-R34-01 (an amount in a
// sentence split across lines) and VISUAL-R34-02 (a line cut in a one-line
// app bar and shown nowhere else) as classes, and a regression sweep
// around the changed code (FitWordsText in dialog bodies, snack bars,
// history lines and the save bar; TitleCutScope and CutTitleHeading on
// every titled screen). Every check walks the charter matrix (320x568 and
// 360x640, 1.0/1.3/2.0, light and dark); r36_real_font_test.dart runs this
// file again with the bundled Familjen Grotesk.
//
// Tests named "QA VISUAL-R36-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/router.dart';

import 'visual_harness.dart';

/// Whether [text] is shown somewhere on screen in full (never cut), alone
/// or inside a longer line.
bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().contains(text) &&
      !p.didExceedMaxLines;
});

final RegExp _money = RegExp(r'[₹$€£¥]|KD|KWD|INR|USD|EUR|JPY');

/// Amount words of multi-line paragraphs wider than their line.
List<String> _brokenAmounts(String at) {
  final out = <String>[];
  for (final e in find.byType(RichText).evaluate()) {
    final p = e.renderObject;
    if (p is! RenderParagraph || !p.hasSize || p.maxLines == 1) continue;
    final span = p.text;
    if (span is! TextSpan) continue;
    final text = span.toPlainText();
    for (final word in text.split(RegExp(r'\s+'))) {
      // An amount: digits with a currency sign or code. The hotspot name and
      // address on Sync's host card wrap by design (a device check).
      if (!RegExp(r'\d').hasMatch(word) || !_money.hasMatch(word)) continue;
      final tp = TextPainter(
        text: TextSpan(text: word, style: span.style),
        textScaler: p.textScaler,
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > p.constraints.maxWidth + 0.5) {
        out.add(
          '$at: "$word" of "$text" is ${tp.width.round()} dp in a '
          '${p.constraints.maxWidth.round()} dp line',
        );
      }
      tp.dispose();
    }
  }
  return out;
}

/// A phone name at the 40-character limit (SPEC 5.16, 8.9).
const String _phone40 = 'Bartholomew Fitzgerald-Johnston Pixel 8a';
const String _phone24 = "Priya's Galaxy S24 Ultra";

SyncRecord _record(String peer, {int minutes = 11}) => SyncRecord(
  id: 'sync-qa-r36-$peer',
  peerName: peer,
  transport: TransportKind.lan,
  startedAt: kNow.subtract(Duration(minutes: minutes + 1)),
  endedAt: kNow.subtract(Duration(minutes: minutes)),
  sentOps: 3,
  receivedOps: 2,
  groupIds: const [],
  outcome: SyncOutcome.completed,
);

/// [v] with a tall screen, so every row of a list is built.
Variant _tall(Variant v) =>
    (size: Size(v.size.width, 2400), scale: v.scale, brightness: v.brightness);

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Regression sweep, VISUAL-R34-01 class: every screen of the
  // Money.maxMinor world (INR and KWD) never breaks an amount word.
  // ------------------------------------------------------------------
  testWidgets('R36 sweep: no screen of the Money.maxMinor world breaks an '
      'amount across lines', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.huge());
    final problems = <String>[];
    for (final v in kVariants) {
      for (final MapEntry(key: name, value: loc) in w.screens.entries) {
        final at = '${variantName(v)} $name';
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, w.phone, v: v, location: loc),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        problems.addAll(_brokenAmounts(at));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => w.phone.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // VISUAL-R34-02 class beyond the app bar: a row that caps a name to one
  // line must show it in full one tap away (KitListRow's contract,
  // lib/ui/widgets/list_row.dart). Sync's "Recent syncs" row
  // (lib/ui/screens/sync/sync_screen.dart, titleLines: 1, no onTap) caps
  // the phone's name; the Activity feed's "Synced with ..." row
  // (SyncRecordRow, titleLines: 1) caps it too and opens Sync. Sync's
  // header line names only the latest sync's phone, so a phone name at
  // the 40-character limit from any earlier sync reads in full nowhere.
  // ------------------------------------------------------------------
  testWidgets(
    'QA VISUAL-R36-01: a 40-character phone name from an earlier sync is '
    "cut in Sync's Recent syncs and in Activity, and reads in full nowhere",
    skip: true, // QA VISUAL-R36-01
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async {
        w = await VisualWorld.realistic();
        w.phone.engine
          ..addHistory(_record(_phone40))
          ..addHistory(_record(_phone24, minutes: 8))
          ..addHistory(_record('Pixel 7', minutes: 5));
      });
      final problems = <String>[];
      for (final v in kVariants) {
        final shown = <String>{};
        for (final loc in [Routes.sync, Routes.activity]) {
          final at = '${variantName(v)} $loc';
          final errors = await collectLayoutErrors(
            () => pumpVisual(t, w.phone, v: _tall(v), location: loc),
          );
          problems.addAll(errors.map((e) => '$at: $e'));
          for (final n in [_phone40, _phone24]) {
            if (_shownInFull(n)) shown.add(n);
          }
          await t.pumpWidget(const SizedBox.shrink());
        }
        for (final n in [_phone40, _phone24]) {
          if (!shown.contains(n)) {
            problems.add('${variantName(v)}: "$n" is cut on Sync and Activity');
          }
        }
      }
      await t.runAsync(() => w.phone.dispose());
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
