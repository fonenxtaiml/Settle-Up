// QA VISUAL round 29, the final regression sweep. What changed in the app
// since round 26 is the Settle up "What changes" list (a payment between
// two others now lists every balance with me it moves, the payer and the
// one paid included: MONEY-R26-01) and the save locks (Settle up, the
// edit forms, Expense detail delete and Edit group hold still while the
// save runs: MONEY-R27-01, MONEY-R28-01). These probes walk those paths
// at the charter's riskiest inputs:
//
// - Settle up between two others with 40-character names and amounts
//   near Money.maxMinor in INR and KWD, over the whole charter matrix:
//   no overflow, no cut amount at any scroll position, every "You and X"
//   row present and read with its direction word.
// - Settle up and Expense detail while the save is held: the locked
//   screen keeps its layout, its amounts and its contrast in both themes.
//
// Tests named "QA VISUAL-R29-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/widgets/settle_controls.dart';

import 'visual_harness.dart';

/// A 40-character name with no space: its first name is all of it, so
/// "You and" plus the first name carries the whole 40 characters.
const _one40 = 'Venkatanarasimharajuvaripetasubramaniamx';

/// An OpStore whose writes wait for [gate] while it is set (a slow disk).
final class _SlowStore implements OpStore {
  final MemoryOpStore inner = MemoryOpStore();
  Completer<void>? gate;

  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() => inner.close();
  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    final g = gate;
    if (g != null) await g.future;
    return inner.insertAll(ops);
  }

  @override
  Future<List<Operation>> loadAll() => inner.loadAll();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer) =>
      inner.missingFor(groupId, peer);
  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) =>
      inner.maxCounter(groupId, deviceId);
  @override
  Future<void> purgeGroup(GroupId groupId) => inner.purgeGroup(groupId);
  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      inner.peerKnowledge(groupId);
  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) => inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<bool> capPeerKnowledge(GroupId groupId, DeviceId deviceId, int max) =>
      inner.capPeerKnowledge(groupId, deviceId, max);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<void> setKv(String key, String? value) => inner.setKv(key, value);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}

/// One group of the "between two others" world: [payer] owes [payee] and
/// a payment of [pay] from [payer] to [payee] moves my balances with both.
typedef _Case = ({
  GroupId g,
  String currency,
  MemberId payer,
  MemberId payee,
  int pay,
  int decimals,
});

typedef _World = ({
  _SlowStore store,
  KvSettingsRepository settings,
  Ledger ledger,
  _Case inr,
  _Case kwd,
  ExpenseId hotel,
});

/// The MONEY-R26-01 shape scaled toward Money.maxMinor, in INR and KWD:
/// Sam paid 60k for me; [_one40] paid 40k, 10k of it mine and 30k owed by
/// [kName40]. Suggested: I pay Sam 60k, [kName40] pays [_one40] 30k, I pay
/// [_one40] 10k. When [kName40] pays [_one40] 50k the debts route again:
/// my balance with each of them moves.
Future<_World> _build() async {
  const k = 1666666666; // 60k = 99,999,999,960 minor, just under maxMinor.
  final store = _SlowStore();
  await store.open();
  final settings = await KvSettingsRepository.open(
    store,
    defaultDeviceName: 'Pixel 8',
    ids: QaIds('dddd0029'),
    localeName: 'en_IN',
  );
  await settings.completeOnboarding(
    displayName: 'Arjun Mehta',
    homeCurrency: 'INR',
  );
  var clock = kNow.millisecondsSinceEpoch - 3600 * 1000;
  final ledger = await Ledger.open(
    store: store,
    keys: MemoryGroupKeyStore(),
    settings: settings,
    ids: QaIds('aaaa0029'),
    nowMillis: () => clock += 1000,
  );
  final myPerson = settings.profile!.personId;
  late ExpenseId hotelId;
  Future<_Case> one(String name, String currency, int decimals) async {
    final g = await ledger.createGroup(
      NewGroup(
        name: name,
        type: GroupType.trip,
        currency: currency,
        simplifyDebts: true,
        newMemberNames: const ['Sam', _one40, kName40],
      ),
    );
    final gs = ledger.current.state.groups[g]!;
    MemberId by(String n) =>
        gs.members.values.firstWhere((m) => m.displayName == n).id;
    final me = gs.memberForPerson(myPerson)!.id;
    final sam = by('Sam'), a = by(_one40), b = by(kName40);
    final date = kNow.subtract(const Duration(hours: 2));
    await ledger.addExpense(
      ExpenseDraft(
        groupId: g,
        description: kDesc120,
        total: 60 * k,
        currency: currency,
        paidBy: SplitSpec.single(sam, 60 * k),
        owedBy: SplitSpec.single(me, 60 * k),
        category: 'food.dining',
        date: date,
      ),
    );
    final hotel = await ledger.addExpense(
      ExpenseDraft(
        groupId: g,
        description: 'Hotel',
        total: 40 * k,
        currency: currency,
        paidBy: SplitSpec.single(a, 40 * k),
        owedBy: SplitSpec(SplitMethod.exact, {me: 10 * k, b: 30 * k}),
        category: 'food.dining',
        date: date,
      ),
    );
    // The lock probe deletes this one: its short description keeps the
    // confirmation clear of VISUAL-R29-01.
    if (currency == 'INR') hotelId = hotel;
    return (
      g: g,
      currency: currency,
      payer: b,
      payee: a,
      pay: 50 * k,
      decimals: decimals,
    );
  }

  final inr = await one(kGroup60, 'INR', 2);
  final kwd = await one('Kuwait $kName40', 'KWD', 3);
  return (
    store: store,
    settings: settings,
    ledger: ledger,
    inr: inr,
    kwd: kwd,
    hotel: hotelId,
  );
}

/// Pumps the real app over [w] at [v] and goes to [location].
Future<ProviderContainer> _pump(
  WidgetTester t,
  _World w,
  Variant v,
  String location,
) async {
  setView(t, v.size);
  await t.runAsync(
    () => w.settings.updateSettings(
      w.settings.settings.copyWith(
        themeMode: v.brightness == Brightness.dark
            ? AppThemeMode.dark
            : AppThemeMode.light,
      ),
    ),
  );
  t.platformDispatcher.textScaleFactorTestValue = v.scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  final c = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(w.settings),
      ledgerRepositoryProvider.overrideWithValue(w.ledger),
      syncEngineProvider.overrideWithValue(FakeSyncEngine(step: Duration.zero)),
      clockProvider.overrideWithValue(() => kNow),
    ],
  );
  addTearDown(c.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(container: c, child: const SettleUpApp()),
  );
  await settleFrames(t);
  c.read(routerProvider).go(location);
  await settleFrames(t);
  return c;
}

String _major(int minor, int decimals) {
  final s = minor.toString().padLeft(decimals + 1, '0');
  return '${s.substring(0, s.length - decimals)}.'
      '${s.substring(s.length - decimals)}';
}

/// Sets the Settle up amount through its own sheet.
Future<void> _enter(WidgetTester t, int minor, int decimals) async {
  final part = find.text('Pay part of it');
  final change = find.text('Change amount');
  final link = part.evaluate().isEmpty ? change : part;
  await t.ensureVisible(link.first);
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(link.first);
  await settleFrames(t);
  await t.enterText(find.byType(TextField).last, _major(minor, decimals));
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(find.text('Done'));
  await settleFrames(t);
}

Finder _vertical() => find.byWidgetPredicate(
  (w) =>
      w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical,
);

/// [check] at the top of the page and every 200 dp down to the end.
Future<void> _walk(WidgetTester t, void Function(String at) check) async {
  final s = _vertical();
  if (s.evaluate().isEmpty) {
    check('@0');
    return;
  }
  final pos = t.state<ScrollableState>(s.first).position;
  pos.jumpTo(0);
  await t.pump(const Duration(milliseconds: 200));
  check('@0');
  for (var i = 0; i < 40 && pos.pixels < pos.maxScrollExtent; i++) {
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await t.pump(const Duration(milliseconds: 200));
    check('@${pos.pixels.round()}');
  }
}

/// Every amount on screen that was cut (see [findCutAmounts]). Names may
/// be ellipsized by design; amounts never.
List<String> _cut(WidgetTester t) => [for (final c in findCutAmounts(t)) '$c'];

Future<List<String>> _contrast(WidgetTester t, String where) async {
  final r = await textContrastGuideline.evaluate(t);
  return r.passed ? const [] : ['$where: ${r.reason}'];
}

void main() {
  configureVisualTests();

  testWidgets('R29 sweep: Settle up between two others lists my balance '
      'with each of them, with 40-character names and amounts near '
      'Money.maxMinor in INR and KWD, with no overflow and no cut amount '
      'over the charter matrix', (t) async {
    late _World w;
    await t.runAsync(() async => w = await _build());
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final cs in [w.inr, w.kwd]) {
      for (final v in kVariants) {
        final where = '${cs.currency} ${variantName(v)}';
        final errors = await collectLayoutErrors(() async {
          await _pump(
            t,
            w,
            v,
            Routes.settle(
              groupId: cs.g,
              from: cs.payer,
              to: cs.payee,
              currency: cs.currency,
            ),
          );
          await _enter(t, cs.pay, cs.decimals);
          await _walk(t, (at) {
            for (final c in _cut(t)) {
              problems.add('$where $at cut: $c');
            }
          });
        });
        for (final e in errors) {
          problems.add('$where: $e');
        }
        final table = t.widget<BeforeAfterTable>(
          find.byType(BeforeAfterTable).last,
        );
        final titles = [for (final e in table.entries) e.title];
        for (final want in ['You and $_one40', 'You and Bartholomew']) {
          if (!titles.contains(want)) {
            problems.add('$where: no "$want" row in $titles');
          }
        }
        // Every "You and" row reads its cells with a direction word.
        for (final label in semanticsLabels(t)) {
          if (!label.startsWith('You and')) continue;
          if (!RegExp(
            r'(owes you|you owe|settled)',
            caseSensitive: false,
          ).hasMatch(label)) {
            problems.add('$where: row read without direction: "$label"');
          }
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await t.runAsync(w.ledger.close);
    expect(problems, isEmpty, reason: problems.take(20).join('\n'));
  });

  testWidgets('R29 sweep: Settle up while the payment is saved holds its '
      'layout, its whole amounts and its text contrast in both themes at '
      '320x568, 1.0x and 2.0x', (t) async {
    late _World w;
    await t.runAsync(() async => w = await _build());
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final b in Brightness.values) {
      for (final scale in const [1.0, 2.0]) {
        final v = (size: const Size(320, 568), scale: scale, brightness: b);
        final where = variantName(v);
        final cs = w.inr;
        w.store.gate = Completer<void>();
        final errors = await collectLayoutErrors(() async {
          await _pump(
            t,
            w,
            v,
            Routes.settle(
              groupId: cs.g,
              from: cs.payer,
              to: cs.payee,
              currency: cs.currency,
            ),
          );
          await _enter(t, cs.pay, cs.decimals);
          final record = find.textContaining(RegExp(r'^Record .* payment$'));
          await t.tap(record);
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await t.pump(const Duration(milliseconds: 300));
          // The save is held: the button is off and the screen is still up.
          final button = t.widget<FilledButton>(
            find.ancestor(of: record, matching: find.byType(FilledButton)),
          );
          if (button.onPressed != null) {
            problems.add('$where: Record still live while saving');
          }
          await _walk(t, (at) {
            for (final c in _cut(t)) {
              problems.add('$where $at cut: $c');
            }
          });
          final s = _vertical();
          t.state<ScrollableState>(s.first).position.jumpTo(0);
          await t.pump(const Duration(milliseconds: 200));
          problems.addAll(await _contrast(t, where));
        });
        for (final e in errors) {
          problems.add('$where: $e');
        }
        w.store.gate!.complete();
        w.store.gate = null;
        await t.runAsync(pumpEventQueue);
        await settleFrames(t);
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await t.runAsync(w.ledger.close);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('R29 sweep: Expense detail while its delete is saved holds '
      'its layout, its whole amounts and its text contrast in both themes '
      'at 320x568, 1.0x and 2.0x', (t) async {
    late _World w;
    await t.runAsync(() async => w = await _build());
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final b in Brightness.values) {
      for (final scale in const [1.0, 2.0]) {
        final v = (size: const Size(320, 568), scale: scale, brightness: b);
        final where = variantName(v);
        final errors = await collectLayoutErrors(() async {
          await _pump(t, w, v, Routes.expense(w.hotel));
          await t.tap(find.byTooltip('More options'));
          await settleFrames(t);
          await t.tap(find.text('Delete expense'));
          await settleFrames(t);
          w.store.gate = Completer<void>();
          await t.tap(find.text('Delete').last);
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await t.pump(const Duration(milliseconds: 300));
          await _walk(t, (at) {
            for (final c in _cut(t)) {
              problems.add('$where $at cut: $c');
            }
          });
          final s = _vertical();
          t.state<ScrollableState>(s.first).position.jumpTo(0);
          await t.pump(const Duration(milliseconds: 200));
          problems.addAll(await _contrast(t, where));
        });
        for (final e in errors) {
          problems.add('$where: $e');
        }
        w.store.gate!.complete();
        w.store.gate = null;
        await t.runAsync(pumpEventQueue);
        await settleFrames(t);
        await t.pumpWidget(const SizedBox.shrink());
        // Put the expense back for the next variant.
        await t.runAsync(
          () => w.ledger.restoreExpense(w.hotel, groupId: w.inr.g),
        );
      }
    }
    handle.dispose();
    await t.runAsync(w.ledger.close);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // VISUAL-R29-01: the confirmation dialogs do not scroll. At 2.0x a long
  // name or description in the title or body pushes the confirm button
  // below the screen, so the task cannot be finished at that text size.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R29-01: a confirmation dialog that carries a long name or '
    'description overflows at 2.0x and pushes its confirm button off the '
    'screen (Delete expense, Delete group, can\'t remove, Share link)',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.longNames());
      Finder scrollable() => find.byType(Scrollable).first;
      Future<void> tapIn(Finder f) async {
        await t.scrollUntilVisible(f, 100, scrollable: scrollable());
        await settleFrames(t);
        await t.tap(f.first);
        await settleFrames(t);
      }

      final openers = <String, Future<void> Function()>{
        'Delete expense (120-character description)': () async {
          await t.tap(find.byTooltip('More options'));
          await settleFrames(t);
          await t.tap(find.text('Delete expense'));
          await settleFrames(t);
        },
        'Delete group (60-character name)': () =>
            tapIn(find.text('Delete group')),
        "can't be removed (40-character name)": () async {
          await tapIn(find.text(kName40));
          await t.tap(find.text('Remove').last);
          await settleFrames(t);
        },
        'Share the invite link (60-character group)': () =>
            tapIn(find.text('Share link')),
      };
      final where = {
        'Delete expense (120-character description)': Routes.expense(w.expense),
        'Delete group (60-character name)': Routes.editGroup(w.group),
        "can't be removed (40-character name)": Routes.members(w.group),
        'Share the invite link (60-character group)': Routes.invite(w.group),
      };
      final problems = <String>[];
      for (final size in const [Size(320, 568), Size(360, 640)]) {
        final v = (size: size, scale: 2.0, brightness: Brightness.light);
        for (final e in openers.entries) {
          final errors = await collectLayoutErrors(() async {
            await pumpVisual(t, w.phone, v: v, location: where[e.key]);
            await e.value();
          });
          final dialog = find.byType(AlertDialog);
          final confirm = find.descendant(
            of: dialog,
            matching: find.byType(FilledButton),
          );
          final at = '${variantName(v)} ${e.key}';
          if (dialog.evaluate().isEmpty) {
            problems.add('$at: dialog did not open');
          } else {
            for (final x in errors) {
              problems.add('$at: $x');
            }
            final r = t.getRect(confirm.first);
            if (r.bottom > size.height) {
              problems.add(
                '$at: confirm button at ${r.top.round()}-'
                '${r.bottom.round()}, below the ${size.height.round()} dp '
                'screen',
              );
            }
          }
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
    skip: true, // QA VISUAL-R29-01: confirmation dialogs do not scroll
  );
}
