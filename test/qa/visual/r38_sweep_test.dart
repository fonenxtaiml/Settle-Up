// QA VISUAL round 38: reverification of VISUAL-R36-01 (a capped phone
// name that reads in full nowhere) as a class, and a regression sweep
// around the changed row (NearbyPhoneRow, which now wraps the phone's name
// in full beside or under its Sync or Pair button). Every check walks the
// charter matrix (320x568 and 360x640, 1.0/1.3/2.0, light and dark);
// r38_real_font_test.dart runs this file again with the bundled Familjen
// Grotesk.
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

/// A phone name at the 40-character limit (SPEC 5.16, 8.9), a second
/// phone of the same owner that differs only at the end, and the most a
/// peer's HELLO may carry (kMaxDeviceNameLength, 100 UTF-16 units).
const String _phone40 = 'Bartholomew Fitzgerald-Johnston Pixel 8a';
const String _phone40b = 'Bartholomew Fitzgerald-Johnston Pixel 9';
final String _phone100 = '${'Bartholomew Fitzgerald-Johnston ' * 3}Pixel';

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

Rect _rect(RenderBox b) => b.localToGlobal(Offset.zero) & b.size;

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Regression sweep around the fix: nearby phones with a wrapped name,
  // sharing a group (Sync) or not (Pair), at 40 characters (two that
  // differ only at the end, and 40 W's) and at HELLO's 100. On a tall
  // view: no overflow, every name in full, the Sync or Pair button never
  // on top of the name or the status line and wholly inside the row, the
  // row's semantics holding the full name, and Pair's label naming the
  // phone in full. At the real height, at the top and scrolled to the
  // end: the 48 dp, labelled tap target and text contrast guidelines.
  // ------------------------------------------------------------------
  testWidgets('R38 sweep: wrapped nearby phone names lay out, read and meet '
      'the guidelines on Sync', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final names = [_phone40, _phone40b, 'W' * 40, _phone100];
    final peers = [
      for (final (i, n) in names.indexed)
        NearbyPeer(
          key: 'k$i',
          name: n,
          transports: {i.isEven ? TransportKind.lan : TransportKind.ble},
          sharedGroupIds: i < 2 ? const [] : [w.group],
        ),
    ];
    final problems = <String>[];
    Future<void> show(Variant v) async {
      await pumpVisual(t, w.phone, v: v, location: Routes.sync);
      w.phone.engine.emitNearby(peers);
      await settleFrames(t);
    }

    for (final v in kVariants) {
      final at = variantName(v);
      final errors = await collectLayoutErrors(() => show(_tall(v)));
      problems.addAll(errors.map((e) => '$at: $e'));
      final rows = find.byType(NearbyPhoneRow);
      if (rows.evaluate().length != peers.length) {
        problems.add('$at: ${rows.evaluate().length} nearby rows');
      }
      for (final n in names) {
        if (!_shownInFull(n)) problems.add('$at: "$n" is cut');
      }
      for (final e in rows.evaluate()) {
        final row = e.widget as NearbyPhoneRow;
        final rowRect = _rect(e.renderObject! as RenderBox);
        final button = find.descendant(
          of: find.byWidget(row),
          matching: find.byWidgetPredicate(
            (w) => w is FilledButton || w is OutlinedButton,
          ),
        );
        if (button.evaluate().length != 1) {
          problems.add('$at "${row.name}": no Sync or Pair button');
          continue;
        }
        final b = _rect(t.renderObject<RenderBox>(button));
        if (!rowRect.inflate(0.5).contains(b.topLeft) ||
            !rowRect.inflate(0.5).contains(b.bottomRight)) {
          problems.add('$at "${row.name}": button $b outside row $rowRect');
        }
        for (final p
            in find
                .descendant(
                  of: find.byWidget(row),
                  matching: find.byType(RichText),
                )
                .evaluate()) {
          final para = p.renderObject! as RenderParagraph;
          final text = para.text.toPlainText();
          if (text == 'Sync' || text == 'Pair' || text.length < 2) continue;
          final r = _rect(para);
          if (r.overlaps(b.deflate(0.5))) {
            problems.add('$at "${row.name}": button $b over "$text" $r');
          }
        }
      }
      final labels = semanticsLabels(t);
      for (final n in names) {
        if (!labels.any((l) => l.contains(n))) {
          problems.add('$at: no semantics label holds "$n"');
        }
      }
      for (final n in names.take(2)) {
        if (!labels.any((l) => l.contains('Pair with $n'))) {
          problems.add('$at: no "Pair with $n" label');
        }
      }
      await t.pumpWidget(const SizedBox.shrink());

      final real = '$at (real height)';
      final realErrors = await collectLayoutErrors(() async {
        await show(v);
        problems.addAll(await _guidelines(t, '$real top'));
        await t.drag(find.byType(Scrollable).first, const Offset(0, -8000));
        await settleFrames(t);
        problems.addAll(await _guidelines(t, '$real end'));
      });
      problems.addAll(realErrors.map((e) => '$real: $e'));
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(() => w.phone.dispose());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // Same class, this phone's own names on Settings. The profile row caps
  // your name to one line (titleLines: 1) and "This phone: <name>" to one
  // line (subtitleLines: 1); the Sync section's Phone name row shows the
  // phone's name in a 160 dp value column with an ellipsis. Tapping either
  // row opens a one-line text field that scrolls the name sideways, so
  // neither a 40-character name nor a 40-character phone name (both at
  // their editor's limit) reads in full anywhere: Members and the group
  // call you "You", and the Activity entry "You added <your name>" is cut
  // too. The phone's name is what friends see when they sync, and two
  // phones of one owner that differ only at the end look the same here.
  // ------------------------------------------------------------------
  testWidgets(
    'QA VISUAL-R38-01: your own 40-character name and phone name are cut '
    'on Settings and read in full nowhere',
    (t) async {
      late VisualPhone p;
      await t.runAsync(() async {
        p = await VisualPhone.create(name: kName40);
        await p.group('Goa trip', ['Sam']);
        await p.settings.setDeviceName(_phone40);
      });
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, p, v: _tall(v), location: Routes.settings),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        if (!_shownInFull(kName40)) {
          problems.add('$at: your name "$kName40" is cut on Settings');
        }
        if (!_shownInFull(_phone40)) {
          problems.add('$at: the phone name "$_phone40" is cut on Settings');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(() => p.dispose());
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
    skip: true, // QA VISUAL-R38-01: your own 40-character name and phone name are cut on Settings and read in full nowhere
  );
}
