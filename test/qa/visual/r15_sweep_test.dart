// QA VISUAL round 15, final regression sweep: the screens outside the
// main layout matrix (onboarding, Nearby host and scan, the sync session,
// claim, new group, group activity, a join link, settle up and a payment
// with one person) at every charter size, text scale and theme in the
// long-name and Money.maxMinor worlds, with the tap target, label and
// contrast guidelines on each in both themes; and the amount field's
// "not a number" message, new since round 6, at the smallest phone and
// largest text; the bottom sheets over Money.maxMinor amounts and the
// name prompts with the keyboard up at every variant; and the Nearby list
// with phone names at the 40-character limit.
//
// Tests named "QA VISUAL-R15-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';

import 'visual_harness.dart';

Map<String, String> _secondary(VisualWorld w) {
  final members = w.phone.gs(w.group).members.values;
  final friend = members.firstWhere((m) => m.personId == w.person).id;
  final me = members.firstWhere((m) => m.personId == w.phone.me).id;
  return {
    'host': Routes.syncHost,
    'scan': Routes.syncScan,
    'session': Routes.syncSession,
    'claim': Routes.claim(w.group),
    'new group': Routes.newGroup,
    'group activity': Routes.groupActivity(w.group),
    'join (bad link)': Routes.join('settleup://not-a-link'),
    'settle with person': Routes.settle(groupId: w.group, from: friend, to: me),
    'new expense for person': Routes.newExpense(personId: w.person),
  };
}

void main() {
  configureVisualTests();

  final worlds = <String, Future<VisualWorld> Function()>{
    'long names': VisualWorld.longNames,
    'huge': VisualWorld.huge,
  };

  for (final world in worlds.entries) {
    testWidgets('${world.key}: the secondary screens fit at every size, '
        'scale and theme', (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await world.value());
      final problems = <String>[];
      for (final s in _secondary(w).entries) {
        for (final v in kVariants) {
          final r = await inspect(tester, w, v, s.value);
          final cut = pureOnly(r.cut);
          if (r.errors.isNotEmpty || cut.isNotEmpty) {
            problems.add(
              '${s.key} ${variantName(v)}: ${r.errors.toSet()} $cut',
            );
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    });
  }

  testWidgets('onboarding fits at every size, scale and theme', (tester) async {
    final problems = <String>[];
    for (final v in kVariants) {
      late VisualPhone p;
      await tester.runAsync(
        () async => p = await VisualPhone.create(onboard: false),
      );
      final errors = await collectLayoutErrors(
        () => pumpVisual(tester, p, v: v, location: Routes.onboarding),
      );
      if (errors.isNotEmpty) problems.add('${variantName(v)}: $errors');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(p.dispose);
    }
    expect(problems, isEmpty);
  });

  for (final b in Brightness.values) {
    testWidgets('the secondary screens meet the tap target, label and '
        'contrast guidelines at 320 dp 1.0x and 2.0x (${b.name})', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.longNames());
      final problems = <String>[];
      for (final scale in const [1.0, 2.0]) {
        // The scan screen's camera has no plugin in widget tests; its
        // controls are swept by the round 9 and 10 tests.
        for (final s in _secondary(w).entries.where((e) => e.key != 'scan')) {
          // Tap targets on the charter phone; contrast on a phone of the
          // same width tall enough that no row is half under a bar (a
          // half-scrolled row is measured against the bar's colour).
          for (final (size, guidelines) in [
            (
              const Size(320, 568),
              [androidTapTargetGuideline, labeledTapTargetGuideline],
            ),
            (const Size(320, 1600), [textContrastGuideline]),
          ]) {
            await pumpVisual(
              tester,
              w.phone,
              v: (size: size, scale: scale, brightness: b),
              location: s.value,
            );
            for (final g in guidelines) {
              final r = await g.evaluate(tester);
              if (!r.passed) problems.add('$scale ${s.key}: ${_why(r)}');
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty);
    });
  }

  for (final b in Brightness.values) {
    testWidgets('the amount field says "Enter the amount as a number" '
        'whole, beside a whole amount, at 320 dp 2.0x (${b.name})', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.longNames());
      final problems = <String>[];
      for (final scale in const [1.0, 1.3, 2.0]) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(
            tester,
            w.phone,
            v: (size: const Size(320, 568), scale: scale, brightness: b),
            location: Routes.newExpense(groupId: w.group),
          );
          final field = find.byType(EditableText).first;
          // A dot-grouped number whose last group is short: no amount.
          await tester.enterText(field, '1.200.50');
          await settleFrames(tester);
        });
        if (errors.isNotEmpty) problems.add('$scale: $errors');
        final msg = find.text('Enter the amount as a number');
        if (msg.evaluate().isEmpty) {
          problems.add('$scale: no message (${visibleTexts(tester).take(12)})');
        } else {
          final p = tester.renderObject<RenderParagraph>(
            find.descendant(of: msg.first, matching: find.byType(RichText)),
          );
          if (p.didExceedMaxLines) problems.add('$scale: message cut');
        }
        await tester.pumpWidget(const SizedBox.shrink());
        // The message's contrast, on a phone tall enough that nothing is
        // half under the app bar.
        await pumpVisual(
          tester,
          w.phone,
          v: (size: const Size(320, 1600), scale: scale, brightness: b),
          location: Routes.newExpense(groupId: w.group),
        );
        await tester.enterText(find.byType(EditableText).first, '1.200.50');
        await settleFrames(tester);
        final r = await textContrastGuideline.evaluate(tester);
        if (!r.passed) problems.add('$scale contrast: ${_why(r)}');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty);
    });
  }

  testWidgets('the sheets fit over Money.maxMinor amounts at every size, '
      'scale and theme', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.huge());
    final members = w.phone.gs(w.group).members.values;
    final friend = members.firstWhere((m) => m.personId == w.person).id;
    final me = members.firstWhere((m) => m.personId == w.phone.me).id;
    final settle = Routes.settle(groupId: w.group, from: friend, to: me);
    final openers = <String, (String, Pattern)>{
      'payer': (Routes.editExpense(w.expense), RegExp(r'^Paid by, ')),
      'category': (Routes.editExpense(w.expense), RegExp(r'^Category: ')),
      'currency': (
        Routes.editExpense(w.expense),
        RegExp(r'^Indian rupee|^INR$'),
      ),
      'group': (Routes.newExpense(), RegExp(r'^Group: ')),
      'settle note': (settle, RegExp(r'^Note, ')),
      'new group currency': (Routes.newGroup, RegExp(r'^Currency, ')),
    };
    final problems = <String>[];
    for (final v in kVariants) {
      for (final e in openers.entries) {
        var opened = false;
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(tester, w.phone, v: v, location: e.value.$1);
          if (!await _semanticTap(tester, e.value.$2)) return;
          await settleFrames(tester);
          opened = find
              .byWidgetPredicate((x) => x is BottomSheet || x is Dialog)
              .evaluate()
              .isNotEmpty;
        });
        final cut = pureOnly(findCutAmounts(tester));
        if (errors.isNotEmpty || !opened || cut.isNotEmpty) {
          problems.add(
            '${variantName(v)} ${e.key} opened=$opened: ${errors.toSet()} $cut',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('the name prompts fit with the keyboard up at every size '
      'and scale', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.longNames());
    final problems = <String>[];
    for (final v in kVariants.where((v) => v.brightness == Brightness.light)) {
      for (final opener in ['Arjun Mehta', 'Pixel 8']) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(tester, w.phone, v: v, location: Routes.settings);
          final f = find.textContaining(opener).first;
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.tap(f);
          await tester.pumpAndSettle();
          // A phone keyboard: 260 dp on a 568 dp phone, 290 dp on 640.
          tester.view.viewInsets = FakeViewPadding(
            bottom: (v.size.height < 600 ? 260 : 290) * 3,
          );
          await tester.pumpAndSettle();
        });
        final open = find.byType(AlertDialog).evaluate().isNotEmpty;
        if (errors.isNotEmpty || !open) {
          problems.add('${variantName(v)} $opener open=$open: $errors');
        }
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty);
  });

  testWidgets('the Nearby list fits with 40-character phone names at every '
      'size, scale and theme, with 48 dp labelled actions', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.longNames());
    // 40 characters, the phone name limit (SPEC 8.9).
    const long = kName40;
    const wide = 'WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW';
    final problems = <String>[];
    for (final v in kVariants) {
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(tester, w.phone, v: v, location: Routes.sync);
        w.phone.engine.emitNearby([
          NearbyPeer(
            key: 'k1',
            name: long,
            transports: const {TransportKind.lan},
            sharedGroupIds: [w.group, w.kwdGroup],
          ),
          const NearbyPeer(
            key: 'k2',
            name: wide,
            transports: {TransportKind.ble},
            sharedGroupIds: [],
          ),
          NearbyPeer(
            key: 'k3',
            name: long,
            transports: const {TransportKind.nearby, TransportKind.ble},
            sharedGroupIds: [w.group],
            moreGroups: true,
          ),
        ]);
        await settleFrames(tester);
      });
      if (errors.isNotEmpty) problems.add('${variantName(v)}: $errors');
      if (v.scale != 1.3) {
        for (final g in [
          androidTapTargetGuideline,
          labeledTapTargetGuideline,
        ]) {
          final r = await g.evaluate(tester);
          if (!r.passed) problems.add('${variantName(v)}: ${_why(r)}');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });
}

SemanticsNode? _node(WidgetTester t, Pattern label) {
  final f = find.semantics.byLabel(label);
  return f.evaluate().isEmpty ? null : f.evaluate().first;
}

/// Semantic tap on the first node whose label matches [label], scrolling
/// the page until it is built.
Future<bool> _semanticTap(WidgetTester t, Pattern label) async {
  for (var i = 0; i < 12 && _node(t, label) == null; i++) {
    final s = find.byWidgetPredicate(
      (x) =>
          x is Scrollable &&
          axisDirectionToAxis(x.axisDirection) == Axis.vertical,
    );
    if (s.evaluate().isEmpty) break;
    final pos = t.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await t.pump(const Duration(milliseconds: 200));
  }
  if (_node(t, label) == null) return false;
  t.semantics.tap(find.semantics.byLabel(label).first);
  await t.pump();
  return true;
}

String _why(Evaluation r) =>
    (r.reason ?? '').trim().split('\n').take(3).join(' ');
