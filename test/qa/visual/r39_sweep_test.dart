// QA VISUAL round 39: reverification of VISUAL-R38-01 (your own name and
// this phone's name cut on Settings and in their editors) as a class, and
// a regression sweep around the changed code: the Settings profile row and
// value rows (_ValueRow, whose value now wraps in full beside or under its
// title) and the shared one-line text prompt (promptText), which now wraps
// on screen instead of scrolling sideways, wherever it is used (Settings,
// Members rename). Every check walks the charter matrix (320x568 and
// 360x640, 1.0/1.3/2.0, light and dark); r39_real_font_test.dart runs this
// file again with the bundled Familjen Grotesk.
//
// Tests named "QA VISUAL-R3x-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'visual_harness.dart';

bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().contains(text) &&
      !p.didExceedMaxLines;
});

const String _phone40 = 'Bartholomew Fitzgerald-Johnston Pixel 8a';

/// A soft keyboard over the bottom of a small phone (dp).
const double _keyboard = 260;

String _why(Evaluation r) => r.reason?.split('\n').first ?? 'failed';

/// The 48 dp tap target, labelled tap target and text contrast guidelines,
/// with a contrast failure measured again with the lists moved 12 dp (the
/// guideline samples 4 dp around a paragraph, so text at a scroll view's
/// edge samples the bar beyond it). A real failure fails in both.
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

Rect _rect(WidgetTester t, Finder f) {
  final b = t.renderObject<RenderBox>(f);
  return b.localToGlobal(Offset.zero) & b.size;
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Settings with a 40-character name and phone name, at the real height,
  // at the top and scrolled to the end: no overflow; the guidelines; the
  // profile row's and the Phone name row's semantics holding each name in
  // full; the Phone name value never over its title; and every value row
  // (Home currency, Default split, Theme, Phone name) with its title and
  // value shown in full.
  // ------------------------------------------------------------------
  testWidgets('R39 sweep: Settings with your 40-character names lays out, '
      'reads and meets the guidelines', (t) async {
    final handle = t.ensureSemantics();
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
        () => pumpVisual(t, p, v: v, location: Routes.settings),
      );
      problems.addAll(errors.map((e) => '$at: $e'));
      problems.addAll(await _guidelines(t, '$at top'));
      // Semantics: both names in full somewhere a screen reader lands.
      final labels = semanticsLabels(t);
      if (!labels.any((l) => l.contains(kName40))) {
        problems.add('$at: no semantics label holds "$kName40"');
      }
      if (!labels.any((l) => l.contains(S.thisPhoneLine(_phone40)))) {
        problems.add('$at: no semantics label holds "This phone: $_phone40"');
      }
      final scroll = find.byType(Scrollable).first;
      await t.scrollUntilVisible(find.text(_phone40), 200, scrollable: scroll);
      await t.pump();
      final labels2 = semanticsLabels(t);
      if (!labels2.any(
        (l) => l.contains(S.phoneName) && l.contains(_phone40),
      )) {
        problems.add('$at: the Phone name row does not read "$_phone40"');
      }
      final title = _rect(t, find.text(S.phoneName));
      final value = _rect(t, find.text(_phone40));
      if (title.overlaps(value)) {
        problems.add('$at: "$_phone40" $value over its title $title');
      }
      if (value.left < -0.5 || value.right > v.size.width + 0.5) {
        problems.add('$at: "$_phone40" at $value is off screen');
      }
      final end = t.state<ScrollableState>(scroll).position;
      end.jumpTo(end.maxScrollExtent);
      await t.pump();
      problems.addAll(await _guidelines(t, '$at end'));
      await t.pumpWidget(const SizedBox.shrink());
      // On a tall view, every row built: each value row's title and value
      // in full, the value never over its title nor off screen.
      await pumpVisual(
        t,
        p,
        v: (
          size: Size(v.size.width, 3200),
          scale: v.scale,
          brightness: v.brightness,
        ),
        location: Routes.settings,
      );
      for (final s in [S.homeCurrency, S.defaultSplit, S.theme, S.phoneName]) {
        if (!_shownInFull(s)) problems.add('$at: "$s" is cut');
        final row = find
            .ancestor(of: find.text(s), matching: find.byType(InkWell))
            .first;
        final tr = _rect(t, find.text(s));
        for (final e
            in find
                .descendant(of: row, matching: find.byType(RichText))
                .evaluate()) {
          final para = e.renderObject! as RenderParagraph;
          final txt = para.text.toPlainText();
          if (txt == s || txt.trim().isEmpty) continue;
          if (para.didExceedMaxLines) {
            problems.add('$at: "$s" value "$txt" cut');
          }
          final r = para.localToGlobal(Offset.zero) & para.size;
          if (r.overlaps(tr)) problems.add('$at: "$s" value "$txt" over it');
          if (r.left < -0.5 || r.right > v.size.width + 0.5) {
            problems.add('$at: "$s" value "$txt" off screen at $r');
          }
        }
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(() => p.dispose());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // The shared one-line prompt, now wrapped, with a soft keyboard up, from
  // every place it opens with a name: Settings > your name, Settings >
  // Phone name, and Members > Rename for a 40-character member (and a
  // 40-W name with no space to break at). No overflow; the editor holds
  // the whole name and never scrolls it sideways; Cancel and Save wholly
  // on screen above the keyboard; the guidelines inside the dialog.
  // ------------------------------------------------------------------
  testWidgets('R39 sweep: the wrapped name prompt lays out above the '
      'keyboard from Settings and Members', (t) async {
    final handle = t.ensureSemantics();
    late VisualPhone p;
    late String gid;
    final w40 = 'W' * 40;
    await t.runAsync(() async {
      p = await VisualPhone.create(name: kName40);
      final g = await p.group('Goa trip', [
        kName40.replaceFirst('B', 'C'),
        w40,
      ]);
      gid = g.g;
      await p.settings.setDeviceName(_phone40);
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final at = variantName(v);
      for (final (where, location, row, text) in [
        ('Settings name', Routes.settings, kName40, kName40),
        ('Settings phone', Routes.settings, S.phoneName, _phone40),
        (
          'Members rename',
          Routes.members(gid),
          kName40.replaceFirst('B', 'C'),
          kName40.replaceFirst('B', 'C'),
        ),
        ('Members rename W', Routes.members(gid), w40, w40),
      ]) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, p, v: v, location: location);
          await t.scrollUntilVisible(
            find.text(row),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await t.pump();
          await t.tap(find.text(row).last);
          await settleFrames(t);
          if (location != Routes.settings) {
            await t.tap(find.text(S.rename).last);
            await settleFrames(t);
          }
          t.view.viewInsets = FakeViewPadding(bottom: _keyboard * 3);
          await settleFrames(t);
        });
        problems.addAll(errors.map((e) => '$at $where: $e'));
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(EditableText),
        );
        if (field.evaluate().length != 1) {
          problems.add('$at $where: no editor');
        } else {
          final ed = t.widget<EditableText>(field);
          if (ed.controller.text != text) {
            problems.add('$at $where: editor holds "${ed.controller.text}"');
          }
          final pos = t
              .state<ScrollableState>(
                find.descendant(of: field, matching: find.byType(Scrollable)),
              )
              .position;
          if (pos.axis != Axis.vertical || pos.maxScrollExtent > 0.5) {
            problems.add(
              '$at $where: the name scrolls ${pos.axis.name} '
              '(${pos.maxScrollExtent} dp out of view)',
            );
          }
        }
        final visible = Rect.fromLTRB(
          0,
          24,
          v.size.width,
          v.size.height - _keyboard,
        );
        for (final b in [S.cancel, S.save]) {
          final f = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(b),
          );
          if (f.evaluate().length != 1) {
            problems.add('$at $where: no "$b" button');
            continue;
          }
          final r = _rect(t, f);
          if (r.top < visible.top - 0.5 || r.bottom > visible.bottom + 0.5) {
            problems.add('$at $where: "$b" at $r not above the keyboard');
          }
        }
        problems.addAll(await _guidelines(t, '$at $where'));
        t.view.resetViewInsets();
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => p.dispose());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
