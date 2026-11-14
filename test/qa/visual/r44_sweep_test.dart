// QA VISUAL round 44: final regression sweep. The only product change
// since round 42 is UIFLOW-R42-01 (lib/ui/screens/group/group_edit_screen
// .dart): Create on New group now refuses text in the person field that is
// no name (no letter or number) the way the keyboard's Done does, with the
// reason under the field, instead of dropping it; a name that repeats one
// already added is still taken as that person and the group is created.
//
// This file walks the changed Create at every size, scale and theme with
// the editor maximums (a 60-character group name, a 40-character person
// chip): the refusal lays out, its reason shows in full on screen above
// the Create bar and TalkBack hears it (a live region), the guidelines
// hold on the refused form, and the repeat path creates the group and
// lands on a group screen that lays out. r44_real_font_test.dart runs this
// file again with Familjen Grotesk.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/form_tiles.dart';

import 'visual_harness.dart';

String _why(Evaluation r) => r.reason?.split('\n').first ?? 'failed';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The 48 dp, labelled tap target and text contrast guidelines; a contrast
/// failure is checked against the label's own ink on the surface (the
/// guideline samples a 1 px per dp screenshot of the 1 em test glyphs, see
/// r42_sweep_test.dart).
Future<List<String>> _guidelines(WidgetTester t, String at) async {
  final out = <String>[];
  for (final g in [
    androidTapTargetGuideline,
    labeledTapTargetGuideline,
    textContrastGuideline,
  ]) {
    final r = await g.evaluate(t);
    if (r.passed) continue;
    if (g != textContrastGuideline) {
      out.add('$at ${g.description}: ${_why(r)}');
      continue;
    }
    final surface = Theme.of(t.element(find.byType(Scaffold).first))
        .colorScheme
        .surface;
    final labels = RegExp(r'label: "([^"]*)"')
        .allMatches(r.reason ?? '')
        .map((m) => m.group(1)!)
        .toSet();
    if (labels.isEmpty) out.add('$at ${g.description}: ${_why(r)}');
    for (final label in labels) {
      for (final e in find.text(label).evaluate()) {
        final p = e.renderObject;
        if (p is! RenderParagraph) continue;
        final style = p.text.style;
        final ink = style?.color;
        if (ink == null) continue;
        final large =
            (style!.fontSize ?? 14) >= 18 ||
            ((style.fontSize ?? 14) >= 14 &&
                (style.fontWeight?.value ?? 400) >= 700);
        final need = large ? 3.0 : 4.5;
        final got = _ratio(Color.alphaBlend(ink, surface), surface);
        if (got < need) {
          out.add(
            '$at: "$label" ink is ${got.toStringAsFixed(2)}:1 on the '
            'surface (needs $need)',
          );
        }
      }
    }
  }
  return out;
}

Finder _field(String label) => find.byElementPredicate((e) {
  if (e.widget is! TextField) return false;
  var labeled = false;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is! LabeledTextField) return true;
    labeled = w.label == label;
    return false;
  });
  return labeled;
});

bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().replaceAll('\n', ' ').contains(text) &&
      !p.didExceedMaxLines;
});

/// Every visible paragraph that exceeded its line limit and reads in full
/// nowhere else on the screen (the one-line app bar cuts a long title by
/// design and the screen's CutTitleHeading shows it, VISUAL-R34-02).
List<String> _cutParagraphs() => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.hasSize &&
            p.didExceedMaxLines &&
            !_shownInFull(p.text.toPlainText().replaceAll('\n', ' ')))
      p.text.toPlainText(),
];

/// Whether a semantics node with [label] is a live region.
bool _liveRegionSays(WidgetTester t, String label) {
  var found = false;
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    if (d.label.contains(label) && d.flagsCollection.isLiveRegion) {
      found = true;
    }
    n.visitChildren((c) {
      visit(c);
      return !found;
    });
  }

  final root =
      t.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  return found;
}

/// Scrolls the form until [f] is built and on screen.
Future<void> _reveal(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(
    f,
    80,
    scrollable: find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first,
    maxScrolls: 80,
  );
  await t.pump();
}

Future<void> _tapText(WidgetTester t, String text) async {
  final f = find.text(text).last;
  await _reveal(t, f);
  await t.pump();
  await t.tap(f, warnIfMissed: false);
  await settleFrames(t);
}

void main() {
  configureVisualTests();

  testWidgets('R44 sweep (UIFLOW-R42-01): New group refuses a non-name on '
      'Create with its reason in full, on screen and heard, at every size, '
      'scale and theme; a repeat still creates the group', (t) async {
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final v in kVariants) {
      final at = variantName(v);
      late VisualPhone p;
      await t.runAsync(() async => p = await VisualPhone.create());
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, p, v: v, location: Routes.newGroup);
        await t.enterText(_field(S.groupName), kGroup60);
        await t.pump();
        await _reveal(t, _field(S.personName));
        await t.enterText(_field(S.personName), kName40);
        await t.pump();
        await _tapText(t, S.addPerson);
        await _reveal(t, _field(S.personName));
        await t.enterText(_field(S.personName), '!!!');
        await t.pump();
        // Create sits in the bar under the form, always on screen.
        await t.tap(find.text(S.createGroupAction), warnIfMissed: false);
        await settleFrames(t);
      });
      problems.addAll(errors.map((e) => '$at refused: $e'));
      if (p.ledger.current.state.visibleGroups.isNotEmpty) {
        problems.add('$at: a group was created with a non-name left');
      }
      for (final c in _cutParagraphs()) {
        problems.add('$at refused: "$c" is cut');
      }
      final reason = find.text(S.nameNeedsLetter);
      if (reason.evaluate().length != 1) {
        problems.add('$at: the reason shows ${reason.evaluate().length}x');
      } else {
        final r = t.getRect(reason);
        final bar = t.getRect(find.text(S.createGroupAction));
        final top = t.getRect(find.byType(AppBar)).bottom;
        if (r.top < top || r.bottom > bar.top - 8) {
          problems.add(
            '$at: the reason $r is not on screen ($top..${bar.top})',
          );
        }
      }
      if (!_liveRegionSays(t, S.nameNeedsLetter)) {
        problems.add('$at: TalkBack is not told "${S.nameNeedsLetter}"');
      }
      await _reveal(t, find.text(kName40));
      if (!_shownInFull(kName40)) {
        problems.add('$at: the added 40-character person is not in full');
      }
      problems.addAll(await _guidelines(t, '$at refused'));

      // The repeat path: the same 40-character name again is that person.
      final created = await collectLayoutErrors(() async {
        await _reveal(t, _field(S.personName));
        await t.enterText(_field(S.personName), kName40);
        await t.pump();
        await t.tap(find.text(S.createGroupAction), warnIfMissed: false);
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
        await settleFrames(t);
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
        await settleFrames(t);
      });
      problems.addAll(created.map((e) => '$at created: $e'));
      final groups = p.ledger.current.state.visibleGroups;
      if (groups.length != 1) {
        problems.add('$at: ${groups.length} groups after the repeat Create');
      } else {
        final names = groups.single.activeMembers
            .map((m) => m.displayName)
            .toList();
        if (names.where((n) => n == kName40).length != 1) {
          problems.add('$at: members after the repeat are $names');
        }
      }
      for (final c in _cutParagraphs()) {
        problems.add('$at group screen: "$c" is cut');
      }
      await t.pumpWidget(const SizedBox.shrink());
      await t.runAsync(p.dispose);
    }
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('R44 sweep: the refused New group form stands still under '
      'Remove animations', (t) async {
    late VisualPhone p;
    await t.runAsync(() async => p = await VisualPhone.create());
    await pumpVisual(
      t,
      p,
      v: kVariants.first,
      location: Routes.newGroup,
      disableAnimations: true,
    );
    await t.enterText(_field(S.groupName), 'Goa');
    await _reveal(t, _field(S.personName));
    await t.enterText(_field(S.personName), '...');
    await t.pump();
    await t.tap(find.text(S.createGroupAction), warnIfMissed: false);
    await settleFrames(t);
    // A text field's caret blinks with or without the setting; unfocus so
    // only the screen's own animations are left.
    FocusManager.instance.primaryFocus?.unfocus();
    await settleFrames(t);
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    expect(t.binding.transientCallbackCount, 0);
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(p.dispose);
  });
}
