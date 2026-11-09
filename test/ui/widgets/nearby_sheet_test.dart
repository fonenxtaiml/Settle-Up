import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  test('meta line names the transport and shared groups', () {
    expect(
      NearbyPeerRow.metaFor(
        {TransportKind.lan, TransportKind.ble},
        ['Goa trip'],
      ),
      'Wi-Fi, shares Goa trip',
    );
    expect(
      NearbyPeerRow.metaFor({TransportKind.nearby}, ['A', 'B']),
      'Bluetooth, shares A and B',
    );
    expect(
      NearbyPeerRow.metaFor({TransportKind.ble}, ['A', 'B', 'C']),
      'Bluetooth, shares A and 2 more',
    );
    expect(
      NearbyPeerRow.metaFor({TransportKind.ble}, []),
      'Bluetooth, no shared groups',
    );
  });

  test('owner name and pairing code helpers', () {
    expect(NearbyPeerRow.ownerFromPhoneName("Priya's Pixel 8"), 'Priya');
    expect(NearbyPeerRow.ownerFromPhoneName('Pixel 8'), 'Pixel');
    expect(PairingCode.grouped('482913'), '482 913');
    expect(PairingCode.grouped('12'), '12');
  });

  testKitVariants(
    'nearby sheet pieces',
    () => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NearbySheetHeader(),
        NearbyPeerRow(
          id: 'a',
          name: "Priya's Pixel 8",
          transports: const {TransportKind.lan},
          sharedGroupNames: const ['Goa trip'],
          onSync: () {},
        ),
        NearbyPeerRow(
          id: 'b',
          name: '',
          transports: const {TransportKind.ble},
          sharedGroupNames: const [],
          onPair: () {},
        ),
        NearbySheetFooter(onShowQr: () {}, onScanQr: () {}),
        const PairingCode(code: '482913', peerName: 'Priya'),
      ],
    ),
    verify: (tester, v) async {
      expect(find.text('Sync'), findsOneWidget);
      expect(find.text('Pair'), findsOneWidget);
      expect(find.text('Unknown phone'), findsOneWidget);
      expect(find.text('482 913'), findsOneWidget);
    },
  );

  testWidgets('sync and pair buttons call back', (tester) async {
    var sync = 0;
    var pair = 0;
    await tester.pumpWidget(
      kitApp(
        Column(
          children: [
            NearbyPeerRow(
              id: 'a',
              name: 'Priya',
              transports: const {TransportKind.lan},
              sharedGroupNames: const ['Goa trip'],
              onSync: () => sync++,
            ),
            NearbyPeerRow(
              id: 'b',
              name: 'Phone',
              transports: const {TransportKind.ble},
              sharedGroupNames: const [],
              onPair: () => pair++,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.tap(find.text('Pair'));
    expect((sync, pair), (1, 1));
  });
}
