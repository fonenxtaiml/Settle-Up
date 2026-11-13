// QA VISUAL round 37: reverification of VISUAL-R36-01 (a capped phone
// name that reads in full nowhere) as a class, and a regression sweep
// around the changed rows (Sync's "Recent syncs" and the Activity feed's
// SyncRecordRow, which now wrap the phone's name in full). Every check
// walks the charter matrix (320x568 and 360x640, 1.0/1.3/2.0, light and
// dark); r37_real_font_test.dart runs this file again with the bundled
// Familjen Grotesk.
//
// Tests named "QA VISUAL-R3x-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/nearby.dart';

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

/// Whether [text] is on screen at all, cut or not.
bool _onScreen(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph && p.text.toPlainText().contains(text);
});

/// A phone name at the 40-character limit (SPEC 5.16, 8.9), and a second
/// phone of the same owner that differs only at the end.
const String _phone40 = 'Bartholomew Fitzgerald-Johnston Pixel 8a';
const String _phone40b = 'Bartholomew Fitzgerald-Johnston Pixel 9 ';

/// The most a peer's HELLO may carry (kMaxDeviceNameLength, 100 UTF-16
/// units): a phone on another build may send more than this app's 40.
final String _phone100 = '${'Bartholomew Fitzgerald-Johnston ' * 3}Pixel';

SyncRecord _record(String peer, int minutes, {bool ok = true}) => SyncRecord(
  id: 'sync-qa-r37-$minutes',
  peerName: peer,
  transport: minutes.isEven ? TransportKind.lan : TransportKind.ble,
  startedAt: kNow.subtract(Duration(minutes: minutes + 1)),
  endedAt: kNow.subtract(Duration(minutes: minutes)),
  sentOps: 1234,
  receivedOps: 5678,
  groupIds: const [],
  outcome: ok ? SyncOutcome.completed : SyncOutcome.failed,
);

/// [v] with a tall screen, so every row of a list is built.
Variant _tall(Variant v) =>
    (size: Size(v.size.width, 3200), scale: v.scale, brightness: v.brightness);

String _why(Evaluation r) => r.reason?.split('\n').first ?? 'failed';

/// The 48 dp tap target, labelled tap target and text contrast guidelines
/// on what is on screen. A contrast failure is measured again with the
/// lists moved 12 dp, as semantics_test.dart does: the guideline samples a
/// paragraph's rect inflated by 4 dp, so text within 4 dp of a scroll
/// view's edge samples the bar beyond it. A real failure fails in both.
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

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Regression sweep around the fix: the wrapped history rows on Sync and
  // Activity, with a 100-unit name (HELLO's limit), a stopped sync, and
  // 4-digit op counts in the trailing "Sent 1234 changes, got 5678". No overflow,
  // every name and the trailing count in full, the full name in the
  // row's semantics, and the tap target, label and contrast guidelines
  // in both themes.
  // ------------------------------------------------------------------
  testWidgets('R37 sweep: wrapped sync history rows lay out, read and meet '
      'the guidelines on Sync and Activity', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    final names = [_phone100, _phone40, _phone40b, 'W' * 40, 'Pixel 7'];
    await t.runAsync(() async {
      w = await VisualWorld.realistic();
      for (final (i, n) in names.indexed.toList().reversed) {
        w.phone.engine.addHistory(_record(n, 2 + i, ok: i != 2));
      }
    });
    final problems = <String>[];
    for (final v in kVariants) {
      for (final loc in [Routes.sync, Routes.activity]) {
        final at = '${variantName(v)} $loc';
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, w.phone, v: _tall(v), location: loc),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        for (final n in names) {
          if (!_shownInFull(n)) problems.add('$at: "$n" is cut');
        }
        final labels = semanticsLabels(t);
        for (final n in names) {
          if (!labels.any((l) => l.contains(n))) {
            problems.add('$at: no semantics label holds "$n"');
          }
        }
        if (loc == Routes.sync &&
            !_shownInFull('Sent 1234 changes, got 5678')) {
          final cut = _onScreen('1234');
          problems.add('$at: the trailing op count is ${cut ? 'cut' : 'gone'}');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      // At the real screen height, at the top and scrolled to the end: no
      // overflow, and the guidelines hold.
      for (final loc in [Routes.sync, Routes.activity]) {
        final at = '${variantName(v)} $loc (real height)';
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, w.phone, v: v, location: loc);
          problems.addAll(await _guidelines(t, '$at top'));
          await t.drag(find.byType(Scrollable).first, const Offset(0, -6000));
          await settleFrames(t);
          problems.addAll(await _guidelines(t, '$at end'));
        });
        problems.addAll(errors.map((e) => '$at: $e'));
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => w.phone.dispose());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // Same class on Home: the sync banner names the latest sync's phone in
  // its subline, which wraps in full (VISUAL-R31-02).
  // ------------------------------------------------------------------
  testWidgets('R37 sweep: Home names the latest sync\'s 40-character phone '
      'in full', (t) async {
    late VisualWorld w;
    await t.runAsync(() async {
      w = await VisualWorld.realistic();
      w.phone.engine.addHistory(_record(_phone40, 3));
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final at = variantName(v);
      final errors = await collectLayoutErrors(
        () => pumpVisual(t, w.phone, v: _tall(v), location: Routes.home),
      );
      problems.addAll(errors.map((e) => '$at: $e'));
      if (!_shownInFull(_phone40)) problems.add('$at: "$_phone40" is cut');
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(() => w.phone.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // VISUAL-R36-01 class, Nearby: NearbyPhoneRow (lib/ui/widgets/nearby.dart)
  // caps the phone's name to one line (titleLines: 1) beside its button.
  // For a phone that shares a group, its Sync button opens the session,
  // whose title names the phone in full. For a phone that shares none,
  // the Pair button only shows a snack ("pairHint") that does not name
  // it, and the row opens nothing: a 40-character name reads in full
  // nowhere, and two phones of one owner that differ only at the end of
  // their names ("... Pixel 8a", "... Pixel 9") look the same.
  // ------------------------------------------------------------------
  testWidgets(
    'QA VISUAL-R36-01: an unknown nearby phone with a 40-character name is '
    'cut in its Pair row, and Pair does not show the name in full',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, w.phone, v: _tall(v), location: Routes.sync);
          w.phone.engine.emitNearby(const [
            NearbyPeer(
              key: 'k1',
              name: _phone40,
              transports: {TransportKind.lan},
              sharedGroupIds: [],
            ),
          ]);
          await settleFrames(t);
        });
        problems.addAll(errors.map((e) => '$at: $e'));
        var shown = _shownInFull(_phone40);
        if (!shown) {
          await t.tap(
            find.descendant(
              of: find.byType(NearbyPhoneRow),
              matching: find.byType(OutlinedButton),
            ),
          );
          await settleFrames(t);
          shown = _shownInFull(_phone40);
        }
        if (!shown) {
          problems.add('$at: "$_phone40" is cut in its row and after Pair');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(() => w.phone.dispose());
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // Control for the repro above: a phone that shares a group reads in full
  // one tap away (its Sync button opens the session).
  testWidgets('R37 sweep: a nearby phone that shares a group reads in full '
      'one tap away, on its Sync button', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final problems = <String>[];
    for (final v in kVariants) {
      final at = variantName(v);
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, w.phone, v: _tall(v), location: Routes.sync);
        w.phone.engine.emitNearby([
          NearbyPeer(
            key: 'k1',
            name: _phone40,
            transports: const {TransportKind.lan},
            sharedGroupIds: [w.group],
          ),
        ]);
        await settleFrames(t);
      });
      problems.addAll(errors.map((e) => '$at: $e'));
      var shown = _shownInFull(_phone40);
      if (!shown) {
        await t.tap(
          find.descendant(
            of: find.byType(NearbyPhoneRow),
            matching: find.byType(FilledButton),
          ),
        );
        await settleFrames(t);
        shown = _shownInFull(_phone40);
      }
      if (!shown) problems.add('$at: "$_phone40" is cut after Sync');
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(() => w.phone.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
