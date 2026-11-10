// QA VISUAL round 9: reverification of the round 8 fix for VISUAL-R8-01
// (48 dp text fields) and the neighbouring cases it touches.
//
// Tests named "QA VISUAL-R9-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/pickers.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

Variant _v(double w, double scale, [Brightness b = Brightness.light]) =>
    (size: Size(w, w <= 320 ? 568 : 640), scale: scale, brightness: b);

/// Text fields on screen under 48 x 48 dp.
List<String> _smallFields(WidgetTester tester, String where) {
  final out = <String>[];
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final e in find.byType(TextField).evaluate()) {
    final r = tester.getRect(find.byWidget(e.widget));
    if (r.bottom <= 0 || r.top >= screen.height) continue;
    if (r.height < 48 - 0.05 || r.width < 48 - 0.05) {
      out.add(
        '$where: field ${r.width.toStringAsFixed(1)} x '
        '${r.height.toStringAsFixed(1)} dp',
      );
    }
  }
  return out;
}

/// Failing nodes of the tap target guidelines, one line each.
Future<List<String>> _guidelines(WidgetTester tester, String where) async {
  final out = <String>[];
  for (final g in [androidTapTargetGuideline, labeledTapTargetGuideline]) {
    final r = await g.evaluate(tester);
    if (r.passed) continue;
    for (final n in (r.reason ?? '').split('SemanticsNode#').skip(1)) {
      out.add('$where: ${n.split('\n').take(2).join(' ')}');
    }
  }
  return out;
}

/// Runs [check] at the top of the first scrollable and every 250 dp down.
Future<List<String>> _sweep(
  WidgetTester tester,
  String where,
  Future<List<String>> Function(String where) check,
) async {
  final out = [...await check(where)];
  final s = find.byType(Scrollable);
  if (s.evaluate().isEmpty) return out;
  for (var i = 0; i < 8; i++) {
    final pos = tester.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 250).clamp(0, pos.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 300));
    out.addAll(await check('$where @${pos.pixels.round()}'));
  }
  return out;
}

/// Enabled nodes that say "button" but have no tap action: TalkBack reads
/// them as buttons and a double tap does nothing.
List<String> _deadButtons(WidgetTester tester, String where) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    final f = d.flagsCollection;
    if (f.isButton &&
        f.isEnabled != Tristate.isFalse &&
        !n.isInvisible &&
        !d.hasAction(SemanticsAction.tap)) {
      out.add('$where: "${d.label.replaceAll('\n', ' ')}"');
    }
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return out;
}

Future<void> _pumpKit(WidgetTester tester, Widget child) async {
  setView(tester, const Size(360, 640));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R8-01 class: every text field in the app, not only the split
  // rows and the payer sheet.
  // ------------------------------------------------------------------

  testWidgets('VISUAL-R8-01 class: every text field on every screen, in '
      'every split method, is at least 48 x 48 dp and meets the tap target '
      'guidelines from 1.0x to 2.0x in both themes', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>{};
    Future<List<String>> check(String where) async => [
      ..._smallFields(tester, where),
      ...await _guidelines(tester, where),
    ];
    final screens = {
      ...w.screens,
      'new group': Routes.newGroup,
      'scan': Routes.syncScan,
      'edit payment': Routes.editExpense(w.payment),
    };
    for (final v in [
      _v(320, 1.0),
      _v(320, 1.15, Brightness.dark),
      _v(360, 1.0, Brightness.dark),
      _v(360, 1.3),
      _v(360, 2.0),
    ]) {
      for (final e in screens.entries) {
        await pumpVisual(tester, w.phone, v: v, location: e.value);
        problems.addAll(
          await _sweep(tester, '${variantName(v)} ${e.key}', check),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
      for (final m in [
        KitStrings.splitExact,
        KitStrings.splitPercent,
        KitStrings.splitShares,
        KitStrings.splitAdjust,
      ]) {
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        await tester.scrollUntilVisible(
          find.text(m),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(m));
        await tester.pump(const Duration(milliseconds: 500));
        problems.addAll(
          await _sweep(tester, '${variantName(v)} split $m', check),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R8-01 class: the text prompt and the currency search '
      'fields are at least 48 dp tall from 1.0x to 2.0x', (tester) async {
    final problems = <String>[];
    for (final scale in [1.0, 1.15, 1.3, 2.0]) {
      for (final which in ['prompt', 'currency']) {
        setView(tester, const Size(320, 568));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (c) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => which == 'prompt'
                        ? promptText(c, title: 'Name', maxLength: 40)
                        : pickCurrency(c, selected: 'INR'),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        problems.addAll(_smallFields(tester, '$which ${scale}x'));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // New findings, round 9 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R9-01: kit buttons wrapped in Semantics(button: true, '
    'excludeSemantics: true) have no semantic tap action, so TalkBack '
    'cannot activate them',
    (tester) async {
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final tapped = <String>[];

      // Each control is enabled (it has an onTap); a semantic tap must
      // reach it, as a finger tap does.
      final kit = <String, Widget>{
        'SplitMethodSelector chip': SplitMethodSelector(
          value: SplitMethod.equal,
          onChanged: (_) => tapped.add('split'),
        ),
        'DropdownChip': DropdownChip(
          label: 'Goa trip',
          semanticLabel: 'Group: Goa trip. Change group',
          onTap: () => tapped.add('dropdown'),
        ),
        'CategoryChip': CategoryChip(
          categoryId: 'transport',
          label: 'Transport',
          onTap: () => tapped.add('category'),
        ),
        'PickerTile': PickerTile(
          label: 'Paid by',
          value: 'You',
          onTap: () => tapped.add('picker'),
        ),
        'KeyValueRow': KeyValueRow(
          label: 'Note',
          value: 'Optional',
          onTap: () => tapped.add('keyvalue'),
        ),
        'NearbyPhoneRow sync': NearbyPhoneRow(
          name: "Priya's Pixel 8",
          subtitle: 'Wi-Fi, shares Goa trip',
          onAction: () => tapped.add('sync'),
        ),
        'NearbyPhoneRow pair': NearbyPhoneRow(
          name: "Sam's phone",
          subtitle: 'Bluetooth',
          action: NearbyPhoneAction.pair,
          onAction: () => tapped.add('pair'),
        ),
        'SyncStatusChip': SyncStatusChip(
          state: SyncChipState.changesWaiting,
          pendingCount: 2,
          onTap: () => tapped.add('chip'),
        ),
        'BalanceHero': BalanceHero(
          net: const {'INR': 12000050},
          owedToMe: const {'INR': 12000050},
          iOwe: const {},
          mainCurrency: 'INR',
          onTap: () => tapped.add('hero'),
        ),
        'AmountField currency': AmountField(
          currency: 'INR',
          currencyName: 'Indian rupee',
          onChanged: (_) {},
          onCurrencyTap: () => tapped.add('currency'),
        ),
      };
      for (final e in kit.entries) {
        await _pumpKit(tester, e.value);
        problems.addAll(_deadButtons(tester, e.key));
        await tester.pumpWidget(const SizedBox.shrink());
      }

      // The shares weight ("Shares for Priya. Tap to type") of the editor,
      // a 36 x 48 dp target the tap target guideline never sees because
      // the node has no tap action.
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(
        tester,
        w.phone,
        v: _v(360, 1.0),
        location: Routes.editExpense(w.expense),
      );
      await tester.scrollUntilVisible(
        find.text(KitStrings.splitShares),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text(KitStrings.splitShares));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
        find.text('Sam'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(seconds: 1));
      problems.addAll(_deadButtons(tester, 'editor, shares'));
      problems.addAll(await _guidelines(tester, 'editor, shares'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
