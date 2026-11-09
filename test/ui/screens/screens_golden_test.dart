// Golden screenshots of every main screen over the seeded demo world, in
// light and dark, at 412 x 915 dp and 2x like the reference renders in
// docs/design/point-to-point/. Regenerate with:
//   flutter test --update-goldens test/ui/screens/screens_golden_test.dart
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/dev/seed_data.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/sync/sync_engine.dart';

import '../widgets/kit_harness.dart';
import 'screen_harness.dart';

typedef _Setup = Future<void> Function(WidgetTester tester, TestWorld w);

Future<void> _go(WidgetTester tester, TestWorld w, String location) async {
  w.go(location);
  await settle(tester);
}

Future<void> _push(WidgetTester tester, TestWorld w, String location) async {
  w.push(location);
  await settle(tester);
}

final Map<String, _Setup> _screens = {
  'home': (tester, w) async {},
  'group': (tester, w) => _push(tester, w, Routes.group(w.g.goa)),
  'add_expense': (tester, w) async {
    await _push(tester, w, Routes.newExpense(groupId: w.g.goa));
    await tester.enterText(find.byType(TextField).first, '2400');
    await tester.enterText(find.byType(TextField).at(1), 'Scooter rental');
    await settle(tester);
    await tester.tap(find.text('Kabir'));
    await tester.tap(find.text('Isha'));
    await settle(tester);
    await tester.tap(find.text('Paid by'));
    await settle(tester);
    await tester.tap(find.text('Priya').last);
    await settle(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
  },
  'settle_up': (tester, w) => _push(
    tester,
    w,
    Routes.settle(
      groupId: w.g.goa,
      from: w.member(w.g.goa, DemoIds.me),
      to: w.member(w.g.goa, DemoIds.priya),
    ),
  ),
  'sync': (tester, w) async {
    await w.engine.startHosting();
    await _go(tester, w, Routes.sync);
  },
  'activity': (tester, w) => _go(tester, w, Routes.activity),
  'expense_detail': (tester, w) async {
    final e = w.ledger.current.state.groups[w.g.goa]!.liveExpenses.firstWhere(
      (e) => e.description == "Dinner at Britto's",
    );
    await _push(tester, w, Routes.expense(e.id));
  },
  'person': (tester, w) => _push(tester, w, Routes.person(DemoIds.priya)),
  'members': (tester, w) => _push(tester, w, Routes.members(w.g.goa)),
  'new_group': (tester, w) => _push(tester, w, Routes.newGroup),
  'settings': (tester, w) => _push(tester, w, Routes.settings),
  'sync_session': (tester, w) async {
    w.engine.emitStatus(
      const SyncStatus(
        discovering: true,
        session: SessionActive(
          SyncProgress(
            peerName: "Priya's Pixel 8",
            transport: TransportKind.lan,
            phase: SyncPhase.transferring,
            sentOps: 2,
            toSendOps: 3,
            receivedOps: 1,
            toReceiveOps: 4,
            verificationCode: '482913',
          ),
        ),
      ),
    );
    await _push(tester, w, Routes.syncSession);
  },
};

void main() {
  setUpAll(() async {
    configureKitTests();
    await loadRealFonts();
  });

  for (final e in _screens.entries) {
    for (final b in Brightness.values) {
      final name = '${e.key}_${b.name}';
      testWidgets('screen $name', (tester) async {
        await _withShadows(() async {
          phoneView(tester);
          final w = await TestWorld.demo();
          await pumpApp(tester, w, brightness: b);
          await e.value(tester, w);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/$name.png'),
          );
        });
      });
    }
  }

  testWidgets('screen onboarding_light', (tester) async {
    await _withShadows(() async {
      phoneView(tester);
      tester.platformDispatcher.localeTestValue = const Locale('en', 'IN');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final w = TestWorld.empty();
      await pumpApp(tester, w);
      await tester.enterText(find.byType(TextField).first, 'Arjun Mehta');
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/onboarding_light.png'),
      );
    });
  });

  testWidgets('screen home_light at text scale 2', (tester) async {
    await _withShadows(() async {
      phoneView(tester, size: const Size(412, 1800));
      final w = await TestWorld.demo();
      await pumpApp(tester, w, textScale: 2);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_light_textscale2.png'),
      );
    });
  });
}

/// Real FAB shadows, as on a phone; restores the test default afterwards.
Future<void> _withShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}
