// QA VISUAL round 10: reverification of the round 9 fix for VISUAL-R9-01
// (kit buttons without a semantic tap action) over the whole class: the
// sheets and dialogs those buttons open, the screens the engineering sweep
// did not visit, the Nearby list with phones in it, and a semantic tap on
// each control in the real app doing what a finger tap does.
//
// Tests named "QA VISUAL-R10-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'visual_harness.dart';

Variant _v(double w, double scale, [Brightness b = Brightness.light]) =>
    (size: Size(w, w <= 320 ? 568 : 640), scale: scale, brightness: b);

final List<Variant> _variants = [
  _v(320, 1.0),
  _v(320, 2.0, Brightness.dark),
  _v(360, 1.3, Brightness.dark),
  _v(360, 2.0),
];

/// Enabled nodes that say "button" but have no tap action.
List<String> _deadButtons(WidgetTester tester, String where) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    final f = d.flagsCollection;
    if (f.isButton &&
        f.isEnabled != Tristate.isFalse &&
        !n.isInvisible &&
        !d.hasAction(SemanticsAction.tap)) {
      out.add('$where: dead button "${d.label.replaceAll('\n', ' ')}"');
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

/// Finger-tappable widgets on screen (an InkWell, a GestureDetector or a
/// Material button with a callback) whose semantics node has no tap
/// action: a finger can use them and TalkBack cannot. [within] limits the
/// search to an open sheet or dialog.
List<String> _deadTaps(WidgetTester tester, String where, {Finder? within}) {
  final out = <String>[];
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  final tappable = find.byWidgetPredicate(
    (w) =>
        (w is InkResponse && (w.onTap != null || w.onLongPress != null)) ||
        (w is GestureDetector && w.onTap != null) ||
        (w is ButtonStyleButton && w.onPressed != null) ||
        (w is IconButton && w.onPressed != null),
  );
  final f = within == null
      ? tappable
      : find.descendant(of: within, matching: tappable);
  for (final e in f.evaluate()) {
    // The framework's text selection handles, not a control.
    var handle = false;
    e.visitAncestorElements((a) {
      handle = '${a.widget.runtimeType}'.contains('SelectionHandleOverlay');
      return !handle;
    });
    if (handle) continue;
    final ro = e.renderObject;
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
    final r = MatrixUtils.transformRect(
      ro.getTransformTo(null),
      Offset.zero & ro.size,
    );
    if (r.bottom <= 0 || r.top >= screen.height || r.width < 1) continue;
    SemanticsNode? n;
    try {
      n = tester.getSemantics(find.byElementPredicate((x) => x == e));
    } catch (_) {
      continue;
    }
    // Merged into a parent: the parent carries the action.
    while (n != null && n.isMergedIntoParent) {
      n = n.parent;
    }
    if (n == null || n.isInvisible) continue;
    final d = n.getSemanticsData();
    if (!d.hasAction(SemanticsAction.tap) &&
        !d.hasAction(SemanticsAction.longPress) &&
        !d.flagsCollection.isTextField) {
      final w = e.widget;
      final text = find
          .descendant(
            of: find.byElementPredicate((x) => x == e),
            matching: find.byType(Text),
          )
          .evaluate()
          .map((t) => (t.widget as Text).data ?? '')
          .join(' ');
      out.add(
        '$where: ${w.runtimeType} "$text" at '
        '${r.left.round()},${r.top.round()} ${r.width.round()}x'
        '${r.height.round()} has node "${d.label}" without tap',
      );
    }
  }
  return out;
}

Future<List<String>> _check(WidgetTester tester, String where) async => [
  ..._deadButtons(tester, where),
  ...await _guidelines(tester, where),
];

/// Runs [_check] at the top of the last scrollable and every 250 dp down.
Future<List<String>> _sweep(WidgetTester tester, String where) async {
  final out = [...await _check(tester, where)];
  final s = _vertical();
  if (s.evaluate().isEmpty) return out;
  for (var i = 0; i < 8; i++) {
    final pos = tester.state<ScrollableState>(s.last).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 250).clamp(0, pos.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 300));
    out.addAll(await _check(tester, '$where @${pos.pixels.round()}'));
  }
  return out;
}

SemanticsNode? _node(WidgetTester tester, Pattern label) {
  final f = find.semantics.byLabel(label);
  final all = f.evaluate().toList();
  return all.isEmpty ? null : all.first;
}

/// Scrolls the page until a node whose label matches [label] is built.
Future<SemanticsNode?> _scrollTo(WidgetTester tester, Pattern label) async {
  for (var i = 0; i < 12 && _node(tester, label) == null; i++) {
    final s = _vertical();
    if (s.evaluate().isEmpty) break;
    final pos = tester.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 200));
  }
  return _node(tester, label);
}

/// Semantic tap on the first node whose label matches [label], scrolling
/// the page until it is built.
Future<bool> _semanticTap(WidgetTester tester, Pattern label) async {
  if (await _scrollTo(tester, label) == null) return false;
  tester.semantics.tap(find.semantics.byLabel(label).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return true;
}

/// The vertical scrollables, the page's own first.
Finder _vertical() => find.byWidgetPredicate(
  (w) =>
      w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical,
);

int _routes(WidgetTester tester) =>
    find.byType(ModalBarrier, skipOffstage: false).evaluate().length;

const List<NearbyPeer> _peers = [
  NearbyPeer(
    key: 'k1',
    name: "Priya's Pixel 8",
    transports: {TransportKind.lan},
    sharedGroupIds: ['g'],
  ),
  NearbyPeer(
    key: 'k2',
    name: "Sam's phone",
    transports: {TransportKind.ble},
    sharedGroupIds: [],
  ),
];

/// Settle up: Priya pays me, the form with its Date and Note rows.
String _settle(VisualWorld w) {
  final gs = w.phone.gs(w.group);
  final me = gs.members.values.firstWhere((m) => m.personId == w.phone.me);
  final f = gs.members.values.firstWhere(
    (m) => m.displayName == 'Priya Sharma',
  );
  return Routes.settle(
    groupId: w.group,
    from: f.id,
    to: me.id,
    currency: 'INR',
  );
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R9-01 reverification, class-wide.
  // ------------------------------------------------------------------

  testWidgets('VISUAL-R9-01 class: in the real app a semantic tap on each '
      'kit button does what a finger tap does', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    final v = _v(360, 1.0);
    final settle = _settle(w);

    // Each opens a sheet, dialog or page over the editor.
    final opens = <String, (String, Pattern)>{
      'Paid by': (Routes.editExpense(w.expense), RegExp(r'^Paid by, ')),
      'Date': (Routes.editExpense(w.expense), RegExp(r'^Date, ')),
      'Category': (Routes.editExpense(w.expense), RegExp(r'^Category: ')),
      'Currency': (
        Routes.editExpense(w.expense),
        RegExp(r'^Indian rupee|^INR$'),
      ),
      'Group chip': (Routes.newExpense(), RegExp(r'^Group: ')),
      'Settle Date': (settle, RegExp(r'^Date, ')),
      'Settle Note': (settle, RegExp(r'^Note, ')),
      'Group currency': (Routes.editGroup(w.group), RegExp(r'^Currency, ')),
      'New group currency': (Routes.newGroup, RegExp(r'^Currency, ')),
    };
    for (final e in opens.entries) {
      await pumpVisual(tester, w.phone, v: v, location: e.value.$1);
      final before = _routes(tester);
      final found = await _semanticTap(tester, e.value.$2);
      if (!found) {
        problems.add('${e.key}: no node labelled ${e.value.$2}');
      } else if (_routes(tester) <= before) {
        problems.add('${e.key}: a semantic tap opened nothing');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }

    // The split method chips select the method.
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
      if (!await _semanticTap(tester, m)) {
        problems.add('split $m: no node');
      } else {
        final d = _node(tester, m)!.getSemanticsData();
        if (d.flagsCollection.isChecked != CheckedState.isTrue) {
          problems.add('split $m: a semantic tap did not select it');
        }
      }
      // The shares weight opens its prompt.
      if (m == KitStrings.splitShares) {
        final before = _routes(tester);
        if (!await _semanticTap(tester, RegExp(r'^Shares for Priya'))) {
          problems.add('shares weight: no node');
        } else if (_routes(tester) <= before) {
          problems.add('shares weight: a semantic tap opened nothing');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }

    // Nearby: Sync starts a sync with that phone.
    await pumpVisual(tester, w.phone, v: v, location: Routes.sync);
    w.phone.engine.emitNearby([
      NearbyPeer(
        key: 'k1',
        name: "Priya's Pixel 8",
        transports: const {TransportKind.lan},
        sharedGroupIds: [w.group],
      ),
    ]);
    await settleFrames(tester);
    // The row merges into one node: "Priya's Pixel 8, Wi-Fi, shares Goa
    // trip, Sync with Priya's Pixel 8", a button whose tap is the Sync.
    if (!await _semanticTap(
      tester,
      RegExp(RegExp.escape(KitStrings.syncWith("Priya's Pixel 8"))),
    )) {
      problems.add('nearby Sync: no node');
    } else if (!w.phone.engine.calls.contains("syncWith:Priya's Pixel 8")) {
      problems.add(
        'nearby Sync: a semantic tap did not start a sync '
        '(${w.phone.engine.calls})',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());

    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R9-01 class: the sheets and dialogs the kit buttons '
      'open, the Nearby list with phones in it, and the screens outside '
      'the engineering sweep have no dead button and meet the tap target '
      'guidelines from 320 dp at 1.0x to 2.0x in both themes', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>{};
    final settle = _settle(w);

    // The date picker is left to the VISUAL-R10-01 and -02 repros.
    final openers = <String, (String, Pattern)>{
      'payer sheet': (Routes.editExpense(w.expense), RegExp(r'^Paid by, ')),
      'category sheet': (Routes.editExpense(w.expense), RegExp(r'^Category: ')),
      'currency sheet': (
        Routes.editExpense(w.expense),
        RegExp(r'^Indian rupee|^INR$'),
      ),
      'group sheet': (Routes.newExpense(), RegExp(r'^Group: ')),
      'settle note': (settle, RegExp(r'^Note, ')),
      'group currency': (Routes.editGroup(w.group), RegExp(r'^Currency, ')),
    };
    final screens = {
      'host': Routes.syncHost,
      'session': Routes.syncSession,
      'claim': Routes.claim(w.group),
      'group activity': Routes.groupActivity(w.group),
    };

    for (final v in _variants) {
      final name = variantName(v);
      for (final e in openers.entries) {
        await pumpVisual(tester, w.phone, v: v, location: e.value.$1);
        final before = _routes(tester);
        if (await _semanticTap(tester, e.value.$2)) {
          await tester.pump(const Duration(milliseconds: 400));
          if (_routes(tester) <= before) {
            problems.add('$name ${e.key}: did not open');
          }
          problems.addAll(await _sweep(tester, '$name ${e.key}'));
        } else {
          problems.add('$name ${e.key}: opener not found');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      for (final e in screens.entries) {
        await pumpVisual(tester, w.phone, v: v, location: e.value);
        problems.addAll(await _sweep(tester, '$name ${e.key}'));
        await tester.pumpWidget(const SizedBox.shrink());
      }
      // Nearby phones: one to sync with, one to pair.
      await pumpVisual(tester, w.phone, v: v, location: Routes.sync);
      w.phone.engine.emitNearby([
        NearbyPeer(
          key: 'k1',
          name: "Priya's Pixel 8",
          transports: const {TransportKind.lan},
          sharedGroupIds: [w.group],
        ),
        _peers[1],
      ]);
      await settleFrames(tester);
      for (final l in [
        KitStrings.syncWith("Priya's Pixel 8"),
        KitStrings.pairWith("Sam's phone"),
      ]) {
        if (await _scrollTo(tester, RegExp(RegExp.escape(l))) == null) {
          problems.add('$name nearby: no "$l"');
        }
      }
      tester.state<ScrollableState>(_vertical().first).position.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 300));
      problems.addAll(await _sweep(tester, '$name nearby'));
      await tester.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R9-01 class, the other way round: everything a '
      'finger can tap on every screen and sheet has a semantic tap', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>{};
    final settle = _settle(w);
    final screens = {
      ...w.screens,
      'new group': Routes.newGroup,
      'scan': Routes.syncScan,
      'host': Routes.syncHost,
      'edit payment': Routes.editExpense(w.payment),
      'settle pair': settle,
    };
    final openers = <String, (String, Pattern)>{
      'payer sheet': (Routes.editExpense(w.expense), RegExp(r'^Paid by, ')),
      'category sheet': (Routes.editExpense(w.expense), RegExp(r'^Category: ')),
      'currency sheet': (
        Routes.editExpense(w.expense),
        RegExp(r'^Indian rupee|^INR$'),
      ),
      'group sheet': (Routes.newExpense(), RegExp(r'^Group: ')),
      'settle note': (settle, RegExp(r'^Note, ')),
    };
    Future<void> sweep(String where, {Finder? within}) async {
      problems.addAll(_deadTaps(tester, where, within: within));
      final s = within == null
          ? _vertical()
          : find.descendant(of: within, matching: _vertical());
      if (s.evaluate().isEmpty) return;
      for (var i = 0; i < 8; i++) {
        final pos = tester.state<ScrollableState>(s.last).position;
        if (pos.pixels >= pos.maxScrollExtent) break;
        pos.jumpTo((pos.pixels + 250).clamp(0, pos.maxScrollExtent));
        await tester.pump(const Duration(milliseconds: 300));
        problems.addAll(
          _deadTaps(tester, '$where @${pos.pixels.round()}', within: within),
        );
      }
    }

    for (final v in [_v(360, 1.0), _v(320, 2.0, Brightness.dark)]) {
      final name = variantName(v);
      for (final e in screens.entries) {
        await pumpVisual(tester, w.phone, v: v, location: e.value);
        await sweep('$name ${e.key}');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      for (final e in openers.entries) {
        await pumpVisual(tester, w.phone, v: v, location: e.value.$1);
        if (await _semanticTap(tester, e.value.$2)) {
          await tester.pump(const Duration(milliseconds: 400));
          final modal = find.byWidgetPredicate(
            (x) => x is BottomSheet || x is Dialog,
          );
          await sweep(
            '$name ${e.key}',
            within: modal.evaluate().isEmpty ? null : modal.last,
          );
        }
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
        await _semanticTap(tester, m);
        await sweep('$name split $m');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R9-01 class: onboarding has no dead button and meets '
      'the tap target guidelines', (tester) async {
    late VisualPhone p;
    await tester.runAsync(
      () async => p = await VisualPhone.create(onboard: false),
    );
    final handle = tester.ensureSemantics();
    final problems = <String>{};
    for (final v in _variants) {
      await pumpVisual(tester, p, v: v, location: Routes.onboarding);
      problems.addAll(await _sweep(tester, '${variantName(v)} onboarding'));
      await tester.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
    await tester.runAsync(p.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // New findings, round 10 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R10-01: at 2.0x the date picker header overflows by 46 dp '
    'and the chosen date wraps over the calendar month row',
    (tester) async {
      await tester.runAsync(loadRealFonts);
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final openers = {
        'expense': Routes.editExpense(w.expense),
        'payment': Routes.editExpense(w.payment),
        'settle': _settle(w),
      };
      for (final v in kVariants) {
        for (final e in openers.entries) {
          final where = '${variantName(v)} ${e.key}';
          var opened = false;
          final errors = await collectLayoutErrors(() async {
            await pumpVisual(tester, w.phone, v: v, location: e.value);
            opened = await _semanticTap(tester, RegExp(r'^Date, '));
          });
          final dialog = find.byType(DatePickerDialog);
          if (!opened || dialog.evaluate().isEmpty) {
            problems.add('$where: the date picker did not open');
          } else {
            for (final err in errors) {
              problems.add('$where: $err');
            }
            // The header box (the Material behind "Select date") and what
            // must show inside it.
            final header = tester.getRect(
              find
                  .ancestor(
                    of: find.text('Select date'),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            final inside = {
              'switch to input': find.descendant(
                of: dialog,
                matching: find.byIcon(Icons.edit_outlined),
              ),
            };
            for (final i in inside.entries) {
              if (i.value.evaluate().isEmpty) continue;
              final r = tester.getRect(i.value.first);
              if (r.bottom > header.bottom + 0.5) {
                problems.add(
                  '$where: ${i.key} ends at ${r.bottom.round()}, below the '
                  'header bottom ${header.bottom.round()}',
                );
              }
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
    skip: true,
  );

  testWidgets(
    'QA VISUAL-R10-02: the date picker day cells are under the 48 dp tap '
    'target (37.7 x 36.6 dp at 320, 43.4 x 46.8 dp at 360)',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      for (final v in [_v(320, 1.0), _v(360, 1.0, Brightness.dark)]) {
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        if (!await _semanticTap(tester, RegExp(r'^Date, '))) {
          problems.add('${variantName(v)}: the date picker did not open');
          continue;
        }
        final r = await androidTapTargetGuideline.evaluate(tester);
        if (!r.passed) {
          final small = (r.reason ?? '')
              .split('SemanticsNode#')
              .skip(1)
              .map((n) => RegExp(r'label: "([^"]*)"').firstMatch(n)?.group(1))
              .whereType<String>()
              .toList();
          final size = RegExp(r'found Size\(([0-9.]+), ([0-9.]+)\)')
              .firstMatch(r.reason ?? '');
          problems.add(
            '${variantName(v)}: ${small.length} day cells under 48 x 48 dp '
            '(${size?.group(1)} x ${size?.group(2)}), e.g. "${small.first}"',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
    skip: true,
  );
}
