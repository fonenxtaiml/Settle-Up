// DATA-R31-01: the clock notice Settings shows (LedgerSnapshot.clockNotice)
// is the same value as Ledger.clockSkewDetected in every state, says why
// (a peer clock ahead, or own changes peers hold back), and follows the
// wall clock: it is re-checked when the app resumes and, while own changes
// are held back, on its own once real time reaches them.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/screens/settings/settings_screen.dart';
import 'package:settle_up/ui/strings.dart';

import '../sync/support/phone.dart';

const int _hour = 60 * 60 * 1000;
const int _day = 24 * _hour;
const int _base = 1767225600000; // 2026-01-01T00:00:00Z

/// A ledger on memory stores whose wall clock is [now].
final class _Phone {
  _Phone._(this.store, this.settings, this.ledger);

  static int now = _base;

  static Future<_Phone> open(String letter, {int Function()? clock}) async {
    final store = MemoryOpStore();
    await store.open();
    final ids = PhoneIds(letter);
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Phone $letter',
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: clock ?? () => now,
    );
    return _Phone._(store, settings, ledger);
  }

  final MemoryOpStore store;
  final KvSettingsRepository settings;
  final Ledger ledger;

  Future<GroupId> group(String name) => ledger.createGroup(
    NewGroup(
      name: name,
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: const ['Sam'],
    ),
  );
}

/// What the notice must be, worked out from the stored ops alone.
ClockNotice _oracle(Ledger l, int now, {required bool peerSeen}) {
  final me = l.current.localDeviceId;
  final held = l.current.ops.any(
    (op) => op.deviceId == me && op.hlc.millis > now + Ledger.maxRemoteAheadMs,
  );
  if (held) return ClockNotice.ownChangesAhead;
  return peerSeen ? ClockNotice.peerAhead : ClockNotice.none;
}

void main() {
  setUp(() => _Phone.now = _base);

  test('own change stamped 30 days ahead: the snapshot carries the notice '
      'the getter reports, with its reason', () async {
    final p = await _Phone.open('a');
    try {
      _Phone.now = _base + 30 * _day;
      final g = await p.group('Far trip');
      _Phone.now = _base;
      // A later change is stamped from the corrected clock and publishes a
      // snapshot that sees the group create held back.
      await p.ledger.updateGroup(g, const GroupPatch(name: 'Far trip 2'));
      expect(p.ledger.clockSkewDetected, isTrue);
      expect(p.ledger.current.clockSkewDetected, isTrue);
      expect(p.ledger.current.clockNotice, ClockNotice.ownChangesAhead);
    } finally {
      await p.ledger.close();
    }
  });

  test('a date change with no other change is published by recheckClock '
      '(both ways), on the watch stream', () async {
    final p = await _Phone.open('a');
    try {
      await p.group('Goa trip');
      expect(p.ledger.current.clockNotice, ClockNotice.none);
      final seen = <ClockNotice>[];
      final sub = p.ledger.watch().listen((s) => seen.add(s.clockNotice));
      await pumpEventQueue();
      // The phone's date is set 10 days back: its own ops now look 10 days
      // ahead of it.
      _Phone.now = _base - 10 * _day;
      expect(p.ledger.clockSkewDetected, isTrue);
      await p.ledger.recheckClock();
      expect(p.ledger.current.clockNotice, ClockNotice.ownChangesAhead);
      // Set right again.
      _Phone.now = _base + _hour;
      await p.ledger.recheckClock();
      expect(p.ledger.current.clockNotice, ClockNotice.none);
      await pumpEventQueue();
      await sub.cancel();
      expect(seen, [
        ClockNotice.none,
        ClockNotice.ownChangesAhead,
        ClockNotice.none,
      ]);
      // Nothing changed: no new snapshot.
      final before = p.ledger.current;
      await p.ledger.recheckClock();
      expect(identical(p.ledger.current, before), isTrue);
    } finally {
      await p.ledger.close();
    }
  });

  test('a peer clock ahead gives peerAhead; own held-back changes outrank '
      'it, and when they clear the peer notice stays', () async {
    final a = await _Phone.open('a');
    late int peerNow;
    final b = await _Phone.open('b', clock: () => peerNow);
    try {
      peerNow = _base + 2 * _hour;
      final g = await b.group('Goa trip');
      await a.ledger.registerJoinedGroup(
        g,
        (await b.ledger.groupKeys())[g]!,
        'Goa trip',
      );
      await a.ledger.applyRemote(g, b.ledger.current.ops.toList());
      expect(a.ledger.current.clockNotice, ClockNotice.peerAhead);
      expect(a.ledger.clockSkewDetected, isTrue);

      _Phone.now = _base + 20 * _day;
      await a.ledger.updateGroup(g, const GroupPatch(name: 'Goa 2026'));
      _Phone.now = _base + 3 * _hour;
      await a.ledger.recheckClock();
      expect(a.ledger.current.clockNotice, ClockNotice.ownChangesAhead);

      _Phone.now = _base + 14 * _day;
      await a.ledger.recheckClock();
      expect(a.ledger.current.clockNotice, ClockNotice.peerAhead);
      expect(a.ledger.current.clockSkewDetected, a.ledger.clockSkewDetected);
    } finally {
      await a.ledger.close();
      await b.ledger.close();
    }
  });

  test('a reopened ledger holding own changes far ahead opens with the '
      'notice', () async {
    final p = await _Phone.open('a');
    _Phone.now = _base + 30 * _day;
    await p.group('Far trip');
    await p.ledger.close();
    _Phone.now = _base;
    final again = await Ledger.open(
      store: p.store,
      keys: MemoryGroupKeyStore(),
      settings: p.settings,
      ids: PhoneIds('a2'),
      nowMillis: () => _Phone.now,
    );
    try {
      expect(again.clockSkewDetected, isTrue);
      expect(again.current.clockNotice, ClockNotice.ownChangesAhead);
    } finally {
      await again.close();
    }
  });

  for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
    test(
      'property (seed $seed): after every command or re-check the '
      'snapshot notice equals the getter and the stored-ops oracle',
      () async {
        final rnd = Random(seed);
        final p = await _Phone.open('a');
        final emitted = <LedgerSnapshot>[];
        final sub = p.ledger.watch().listen(emitted.add);
        try {
          final groups = <GroupId>[];
          for (var step = 0; step < 60; step++) {
            final kind = rnd.nextInt(4);
            if (kind == 0 || groups.isEmpty) {
              groups.add(await p.group('Trip $step'));
            } else if (kind == 1) {
              await p.ledger.updateGroup(
                groups[rnd.nextInt(groups.length)],
                GroupPatch(name: 'Trip $step'),
              );
            } else if (kind == 2) {
              // The date moves anywhere from 20 days back to 40 days ahead.
              _Phone.now =
                  _base + (rnd.nextInt(60) - 20) * _day + rnd.nextInt(_day);
              // The getter is live even before anything is published.
              expect(
                p.ledger.clockSkewDetected,
                _oracle(p.ledger, _Phone.now, peerSeen: false) !=
                    ClockNotice.none,
                reason: 'step $step: getter',
              );
              continue;
            } else {
              await p.ledger.recheckClock();
            }
            final want = _oracle(p.ledger, _Phone.now, peerSeen: false);
            expect(p.ledger.current.clockNotice, want, reason: 'step $step');
            expect(
              p.ledger.current.clockSkewDetected,
              p.ledger.clockSkewDetected,
              reason: 'step $step: snapshot and getter',
            );
            await pumpEventQueue();
            expect(
              identical(emitted.last, p.ledger.current),
              isTrue,
              reason: 'step $step: the current snapshot was published',
            );
          }
        } finally {
          await sub.cancel();
          await p.ledger.close();
        }
      },
    );
  }

  testWidgets('the notice clears on its own once real time reaches the '
      'held-back change, with no other change and no resume', (tester) async {
    // Fake time: the ledger's wall clock follows the test's elapsed time.
    var elapsed = 0;
    final p = await _Phone.open('a', clock: () => _base + elapsed);
    try {
      elapsed = 9 * _day;
      final g = await p.group('Far trip');
      elapsed = 0;
      await p.ledger.updateGroup(g, const GroupPatch(name: 'Far trip 2'));
      expect(p.ledger.current.clockNotice, ClockNotice.ownChangesAhead);
      // It clears 2 days on (9 days ahead minus the 7 days peers accept).
      var clearedAt = -1;
      for (var h = 1; h <= 3 * 24; h++) {
        elapsed = h * _hour;
        await tester.pump(const Duration(hours: 1));
        if (p.ledger.current.clockNotice == ClockNotice.none) {
          clearedAt = h;
          break;
        }
      }
      expect(clearedAt, inInclusiveRange(48, 49));
      expect(p.ledger.clockSkewDetected, isFalse);
    } finally {
      await p.ledger.close();
    }
  });

  group('Settings explains the notice', () {
    Future<void> pumpSettings(WidgetTester tester, _Phone phone) async {
      final engine = DefaultSyncEngine(store: phone.ledger, transports: []);
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(phone.settings),
            ledgerRepositoryProvider.overrideWithValue(phone.ledger),
            syncEngineProvider.overrideWithValue(engine),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump();
      addTearDown(() => tester.runAsync(engine.dispose));
    }

    Future<_Phone> farPhone(WidgetTester tester, {required bool own}) async {
      late _Phone p;
      await tester.runAsync(() async {
        p = await _Phone.open('c');
        if (own) {
          _Phone.now = _base + 30 * _day;
          final g = await p.group('Far trip');
          _Phone.now = _base;
          await p.ledger.updateGroup(g, const GroupPatch(name: 'Far 2'));
        } else {
          late int peerNow;
          final b = await _Phone.open('d', clock: () => peerNow);
          peerNow = _base + 2 * _hour;
          final g = await b.group('Goa trip');
          await p.ledger.registerJoinedGroup(
            g,
            (await b.ledger.groupKeys())[g]!,
            'Goa trip',
          );
          await p.ledger.applyRemote(g, b.ledger.current.ops.toList());
          await b.ledger.close();
        }
      });
      return p;
    }

    for (final own in [true, false]) {
      testWidgets(
        own
            ? 'own changes held back: the notice says why they wait'
            : 'a peer clock ahead: the notice says a phone was ahead',
        (tester) async {
          final p = await farPhone(tester, own: own);
          try {
            expect(
              p.ledger.current.clockNotice,
              own ? ClockNotice.ownChangesAhead : ClockNotice.peerAhead,
            );
            await pumpSettings(tester, p);
            expect(find.text(S.clockLooksWrong), findsOneWidget);
            expect(
              find.text(S.clockOwnChangesAheadHelp),
              own ? findsOneWidget : findsNothing,
            );
            expect(
              find.text(S.clockLooksWrongHelp),
              own ? findsNothing : findsOneWidget,
            );
            await tester.pumpWidget(const SizedBox());
          } finally {
            await tester.runAsync(p.ledger.close);
          }
        },
      );
    }
  });
}
