// QA DATA round 29: the "This phone's clock looks wrong" notice.
//
// SPEC 7.x (skew guard) and the device checklist in docs/qa/QA-REPORT.md
// (SYNC-R1-01/02) say Settings shows "This phone's clock looks wrong" once
// Ledger.clockSkewDetected is set. The flag is set by the data layer (a peer
// stamp more than an hour ahead, or ops held back as more than 7 days
// ahead), but nothing in lib/ui reads it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

import '../../sync/support/phone.dart';

void main() {
  late TestPhone alex;
  late Ledger ahead;
  late DefaultSyncEngine engine;

  setUp(() async {
    alex = await TestPhone.create('a', deviceName: 'Alex');
    // A peer whose clock runs 2 hours ahead creates a group and Alex
    // receives it: Alex's ledger flags the skew.
    final store = MemoryOpStore();
    await store.open();
    final ids = PhoneIds('b');
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Priya',
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(
      displayName: 'Priya',
      homeCurrency: 'INR',
    );
    ahead = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: () =>
          DateTime.now().millisecondsSinceEpoch + 2 * 60 * 60 * 1000,
    );
    final g = await ahead.createGroup(
      const NewGroup(
        name: 'Goa trip',
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: ['Sam'],
      ),
    );
    await alex.ledger.registerJoinedGroup(
      g,
      (await ahead.groupKeys())[g]!,
      'Goa trip',
    );
    await alex.ledger.applyRemote(g, ahead.current.ops.toList());
    engine = DefaultSyncEngine(store: alex.ledger, transports: []);
  });

  tearDown(() async {
    await engine.dispose();
    await ahead.close();
    await alex.close();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    // Tall enough that the whole list, About included, is built.
    tester.view.physicalSize = const Size(1080, 6000);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(alex.settings),
          ledgerRepositoryProvider.overrideWithValue(alex.ledger),
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
  }

  testWidgets('probe: the flag is set and Settings builds its About section', (
    tester,
  ) async {
    expect(alex.ledger.clockSkewDetected, isTrue);
    await pumpSettings(tester);
    expect(
      find.text('Version'),
      findsOneWidget,
      reason: 'the About section is on screen',
    );
  });

  testWidgets(
    'QA DATA-R29-02 repro: Settings says "This phone\'s clock looks wrong" '
    'once a skewed peer clock was seen',
    (tester) async {
      expect(alex.ledger.clockSkewDetected, isTrue);
      await pumpSettings(tester);
      expect(
        find.textContaining("This phone's clock looks wrong"),
        findsOneWidget,
      );
    },
  );

  testWidgets('regression: the snapshot carries the flag Settings reads', (
    tester,
  ) async {
    expect(alex.ledger.current.clockSkewDetected, isTrue);
    expect(ahead.current.clockSkewDetected, isFalse);
  });

  test('regression: ops all held back as too far ahead still publish the '
      'flag on a new snapshot', () async {
    final store = MemoryOpStore();
    await store.open();
    final ids = PhoneIds('d');
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Far',
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: 'Far', homeCurrency: 'INR');
    final far = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: () =>
          DateTime.now().millisecondsSinceEpoch + 8 * 24 * 60 * 60 * 1000,
    );
    final cara = await TestPhone.create('e', deviceName: 'Cara');
    try {
      final g = await far.createGroup(
        const NewGroup(
          name: 'Far trip',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['Sam'],
        ),
      );
      await cara.ledger.registerJoinedGroup(
        g,
        (await far.groupKeys())[g]!,
        'Far trip',
      );
      expect(cara.ledger.current.clockSkewDetected, isFalse);
      final seen = <bool>[];
      final sub = cara.ledger.watch().listen(
        (s) => seen.add(s.clockSkewDetected),
      );
      final added = await cara.ledger.applyRemote(g, far.current.ops.toList());
      await pumpEventQueue();
      await sub.cancel();
      expect(added, isEmpty, reason: 'every op is more than 7 days ahead');
      expect(cara.ledger.current.clockSkewDetected, isTrue);
      expect(seen.last, isTrue, reason: 'Settings hears about it');
    } finally {
      await far.close();
      await cara.close();
    }
  });

  testWidgets('regression: no clock notice on a phone that saw no skew', (
    tester,
  ) async {
    late TestPhone bob;
    await tester.runAsync(
      () async => bob = await TestPhone.create('c', deviceName: 'Bob'),
    );
    final bobEngine = DefaultSyncEngine(store: bob.ledger, transports: []);
    try {
      expect(bob.ledger.clockSkewDetected, isFalse);
      tester.view.physicalSize = const Size(1080, 6000);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(bob.settings),
            ledgerRepositoryProvider.overrideWithValue(bob.ledger),
            syncEngineProvider.overrideWithValue(bobEngine),
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
      expect(find.text('Version'), findsOneWidget);
      expect(find.textContaining('clock looks wrong'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await tester.runAsync(() async {
        await bobEngine.dispose();
        await bob.close();
      });
    }
  });
}
