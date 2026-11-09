import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'gallery_screens.dart';
import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);
  final now = DateTime(2026, 11, 9, 10);

  group('SyncStatusChip', () {
    testKitVariants(
      'every state',
      () => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          const SyncStatusChip(state: SyncChipState.neverSynced),
          SyncStatusChip(
            state: SyncChipState.allShared,
            lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
          const SyncStatusChip(
            state: SyncChipState.changesWaiting,
            pendingCount: 3,
          ),
          const SyncStatusChip(
            state: SyncChipState.inProgress,
            peerName: 'Priya',
          ),
          const SyncStatusChip(state: SyncChipState.failed),
        ],
      ),
      verify: (tester, _) async {
        expect(find.text('On this phone'), findsOneWidget);
        expect(find.text('Synced 5 min ago'), findsOneWidget);
        expect(find.text('3 changes to share'), findsOneWidget);
        expect(find.text('Syncing with Priya'), findsOneWidget);
        expect(find.text('Sync stopped'), findsOneWidget);
      },
    );

    test('never says offline', () {
      for (final s in SyncChipState.values) {
        final chip = SyncStatusChip(state: s, pendingCount: 1);
        expect(chip.label.toLowerCase(), isNot(contains('offline')));
      }
      expect(
        const SyncStatusChip(
          state: SyncChipState.changesWaiting,
          pendingCount: 1,
        ).label,
        '1 change to share',
      );
    });
  });

  group('SyncBanner', () {
    testKitVariants(
      'changes waiting',
      () => SyncBanner(
        state: SyncChipState.changesWaiting,
        pendingCount: 3,
        peerName: "Priya's Pixel 8",
        lastSyncedAt: now.subtract(const Duration(hours: 26)),
        now: now,
        onTap: () {},
        onSync: () {},
      ),
      verify: (tester, _) async {
        expect(find.text('3 changes to share'), findsOneWidget);
        expect(
          find.text("Last synced with Priya's Pixel 8 yesterday"),
          findsOneWidget,
        );
        expect(find.text('Sync'), findsOneWidget);
      },
    );

    testKitVariants(
      'in progress, failed, never synced',
      () => Column(
        children: [
          const SyncBanner(
            state: SyncChipState.inProgress,
            pendingCount: 2,
            peerName: "Ravi's iPhone",
          ),
          SyncBanner(state: SyncChipState.failed, onSync: () {}),
          const SyncBanner(state: SyncChipState.neverSynced),
        ],
      ),
      verify: (tester, _) async {
        expect(find.text("Syncing with Ravi's iPhone"), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Sync stopped'), findsOneWidget);
        expect(find.text('Not synced with another phone yet'), findsOneWidget);
      },
    );

    testWidgets('card opens sync, button starts it', (tester) async {
      var opened = 0;
      var synced = 0;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(
          SyncBanner(
            state: SyncChipState.changesWaiting,
            pendingCount: 3,
            onTap: () => opened++,
            onSync: () => synced++,
          ),
        ),
      );
      await tester.tap(find.text('Sync'));
      await tester.tap(find.text('3 changes to share'));
      expect((opened, synced), (1, 1));
      expect(find.bySemanticsLabel('Sync, 3 changes to share'), findsOneWidget);
      handle.dispose();
    });
  });

  group('nearby and hosting', () {
    testKitVariants(
      'nearby phone rows',
      () => ListSection(
        title: 'Nearby phones',
        titleAction: const LookingIndicator(),
        children: [
          NearbyPhoneRow(
            name: "Priya's Pixel 8",
            subtitle: 'Wi-Fi, shares Goa trip',
            onAction: () {},
          ),
          NearbyPhoneRow(
            name: "Ravi's iPhone",
            subtitle: 'Bluetooth, shares Goa trip',
            kind: NearbyPhoneKind.iphone,
            action: NearbyPhoneAction.busy,
          ),
          NearbyPhoneRow(
            name: 'Unknown phone',
            subtitle: 'Bluetooth, no shared groups',
            kind: NearbyPhoneKind.unknown,
            action: NearbyPhoneAction.pair,
            onAction: () {},
          ),
          const NearbyPhoneRow(
            name: 'Old phone',
            subtitle: 'Wi-Fi',
            action: NearbyPhoneAction.none,
          ),
        ],
      ),
      verify: (tester, _) async {
        expect(find.widgetWithText(FilledButton, 'Sync'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Pair'), findsOneWidget);
        expect(find.text('Looking'), findsOneWidget);
      },
    );

    testWidgets('row buttons name the phone', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        kitApp(
          Column(
            children: [
              NearbyPhoneRow(
                name: "Priya's Pixel 8",
                subtitle: 'Wi-Fi',
                onAction: () => taps++,
              ),
              NearbyPhoneRow(
                name: 'Unknown phone',
                subtitle: 'Bluetooth',
                action: NearbyPhoneAction.pair,
                onAction: () => taps++,
              ),
            ],
          ),
        ),
      );
      expect(
        find.bySemanticsLabel(RegExp("Sync with Priya's Pixel 8")),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('Pair with Unknown phone')),
        findsOneWidget,
      );
      await tester.tap(find.text('Sync'));
      await tester.tap(find.text('Pair'));
      expect(taps, 2);
      handle.dispose();
    });

    Widget host({bool visible = true, ValueChanged<bool>? onChanged}) =>
        HostQrCard(
          visible: visible,
          onVisibleChanged: onChanged ?? (_) {},
          subtitle: 'On your hotspot, for 4:58 more',
          qrData: 'settleup://connect?h=192.168.43.1:7420',
          address: '192.168.43.1:7420',
          hotspotName: 'AndroidAP_4B',
        );

    testKitVariants(
      'host card visible',
      host,
      verify: (tester, _) async {
        expect(find.byType(QrImageView), findsOneWidget);
        expect(find.text('192.168.43.1:7420'), findsOneWidget);
        expect(find.text('AndroidAP_4B'), findsOneWidget);
      },
    );

    testWidgets('hidden card has no QR; the switch reports changes', (
      tester,
    ) async {
      bool? value;
      await tester.pumpWidget(
        kitApp(host(visible: false, onChanged: (v) => value = v)),
      );
      expect(find.byType(QrImageView), findsNothing);
      await tester.tap(find.byType(Switch));
      expect(value, isTrue);
    });

    testWidgets('the QR stays dark on white in dark mode', (tester) async {
      await tester.pumpWidget(kitApp(host(), brightness: Brightness.dark));
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr.backgroundColor, const Color(0xFFFFFFFF));
      expect(qr.semanticsLabel, 'QR code to sync with this phone');
    });
  });

  group('chrome', () {
    testWidgets('navigation bar with a sync badge', (tester) async {
      var picked = -1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            bottomNavigationBar: AppNavigationBar(
              selectedIndex: 0,
              onDestinationSelected: (i) => picked = i,
              pendingCount: 3,
            ),
          ),
        ),
      );
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      await tester.tap(find.text('Sync'));
      expect(picked, 2);
      expect(
        tester.getSize(find.byType(NavigationBar)).height,
        greaterThanOrEqualTo(80),
      );
    });

    testWidgets('no badge when everything is shared', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            bottomNavigationBar: AppNavigationBar(
              selectedIndex: 2,
              onDestinationSelected: (_) {},
            ),
          ),
        ),
      );
      final badge = tester.widget<Badge>(find.byType(Badge).first);
      expect(badge.isLabelVisible, isFalse);
    });

    testWidgets('extended ink FAB', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            floatingActionButton: AddExpenseFab(onPressed: () => taps++),
          ),
        ),
      );
      await tester.tap(find.text('Add expense'));
      expect(taps, 1);
      final fab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      expect(fab.isExtended, isTrue);
      final theme = AppTheme.light().floatingActionButtonTheme;
      expect(theme.backgroundColor, const Color(0xFF16191D));
    });
  });

  group('reference screens fit a 360 dp phone', () {
    final screens = <String, Widget Function()>{
      'home': () => const HomeScreen(),
      'group': () => const GroupScreen(),
      'add expense': () => const AddExpenseScreen(),
      'settle up': () => const SettleScreen(),
      'sync': () => const SyncScreen(),
    };
    for (final e in screens.entries) {
      for (final v in kitVariants) {
        testWidgets('${e.key} (${variantName(v)})', (tester) async {
          tester.view.physicalSize = const Size(360, 780) * 3;
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: v.$1 == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(v.$2)),
                child: child!,
              ),
              home: e.value(),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          // Scroll to the end so every row lays out once.
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -4000),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
