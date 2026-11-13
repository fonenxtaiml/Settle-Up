// QA SECURITY round 17: reverification of SECURITY-R15-01 and -02.
//
// SECURITY-R17-01: the SECURITY-R15-01 fix made SightingCache and
// NearbyRegistry cost O(log n) per sighting, but the Sync screen still
// builds every listed nearby phone on every change of the list.
// SyncScreen puts all rows in one ListSection, a single child of the
// screen's ListView, so none of them is built lazily. A stranger on the
// same Wi-Fi who announces many `_settleup._tcp` services (one host, many
// ports, as in the SECURITY-R15-01 flood) gets one row per service, and
// can change one row at will (a goodbye and a new service), which
// rebuilds and lays out all of them in the next frame on the UI isolate.
// On the test runner one such frame takes about 0.3 s with 200 rows,
// 1 s with 1,200 and 2.4 s with 2,400: linear in a number the stranger
// chooses, with no cap.
//
// testWidgets only takes a bool skip, so the id is in the test name and in
// the comment next to `skip: true`; unskip to verify a fix.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/nearby.dart';

import '../../ui/screens/screen_harness.dart';

/// [n] forged LAN services of one host; [gen] renames the first one.
List<NearbyPeer> _forged(int n, int gen) => [
  for (var i = 0; i < n; i++)
    NearbyPeer(
      key: 'lan|10.0.0.66:${20000 + i}',
      name: i == 0 ? 'Phone $i v$gen' : 'Phone $i',
      transports: const {TransportKind.lan},
      sharedGroupIds: const [],
    ),
];

/// How many nearby rows the frame after a change of one row builds.
Future<int> _rowsBuiltOnChange(WidgetTester tester, int n) async {
  phoneView(tester);
  final world = await TestWorld.demo();
  await pumpApp(tester, world, location: Routes.sync);
  world.engine.emitNearby(_forged(n, 0));
  await tester.pump();
  await tester.pump();
  world.engine.emitNearby(_forged(n, 1));
  await tester.pump();
  await tester.pump();
  return find.byType(NearbyPhoneRow).evaluate().length;
}

void main() {
  group('SECURITY-R17-01: a flood of forged services rebuilds every row', () {
    testWidgets(
      'QA SECURITY-R17-01: a change in a list of 1,200 forged phones '
      'builds only the rows on screen',
      (tester) async {
        final built = await _rowsBuiltOnChange(tester, 1200);
        // A 915 dp phone shows a few rows; a lazy list builds those and
        // its cache extent, far fewer than 100.
        expect(built, lessThan(100), reason: '$built rows built');
      },
    );

    testWidgets('control: a short nearby list shows every phone', (
      tester,
    ) async {
      final built = await _rowsBuiltOnChange(tester, 5);
      expect(built, 5);
    });
  });
}
