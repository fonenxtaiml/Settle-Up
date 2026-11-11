// QA SECURITY round 18: reverification probes for SECURITY-R17-01.
//
// SECURITY-R17-01 (fixed): the Sync screen built every nearby row on each
// change of the nearby list, so a stranger who announced thousands of
// services could jank the screen by churning one. The fix makes the screen
// a CustomScrollView and the rows a lazily built SliverListSection. These
// probes check the whole class, not only the repro's single input: the
// frame cost after a change at list lengths far beyond the repro, a user
// scrolled deep into the forged rows, churn that changes the list length
// (goodbye plus a new service), TalkBack's semantics tree being on, and a
// flood that collapses while the user is scrolled far down.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/nearby.dart';

import '../../ui/screens/screen_harness.dart';

NearbyPeer _peer(int i, {String suffix = ''}) => NearbyPeer(
  key: 'lan|10.0.0.66:${20000 + i}',
  name: 'Forged $i$suffix',
  transports: const {TransportKind.lan},
  sharedGroupIds: const [],
);

/// [n] forged services; [gen] renames the first one.
List<NearbyPeer> _forged(int n, int gen) => [
  for (var i = 0; i < n; i++) _peer(i, suffix: i == 0 ? ' v$gen' : ''),
];

int get _rows => find.byType(NearbyPhoneRow).evaluate().length;

Future<void> _open(WidgetTester tester, List<NearbyPeer> peers) async {
  phoneView(tester);
  final world = await TestWorld.demo();
  await pumpApp(tester, world, location: Routes.sync);
  world.engine.emitNearby(peers);
  await tester.pump();
  await tester.pump();
  _world = world;
}

late TestWorld _world;

/// Emits [peers] and returns how long the frames that show them take.
Future<Duration> _change(WidgetTester tester, List<NearbyPeer> peers) async {
  final sw = Stopwatch()..start();
  _world.engine.emitNearby(peers);
  await tester.pump();
  await tester.pump();
  return sw.elapsed;
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  group('SECURITY-R17-01 class: forged services cost a frame the same at '
      'any count', () {
    for (final n in const [10, 2400, 20000]) {
      testWidgets('$n forged phones: one renamed row costs a bounded frame', (
        tester,
      ) async {
        await _open(tester, _forged(n, 0));
        final took = await _change(tester, _forged(n, 1));
        // ignore: avoid_print
        print(
          'R18 probe: $n rows, frame after a change: '
          '${took.inMilliseconds} ms, $_rows rows built',
        );
        expect(_rows, lessThan(40));
        expect(find.text('Forged 0 v1'), findsOneWidget);
        // Before the fix 2,400 rows took 2-2.6 s here and the cost was
        // linear, so 20,000 would take about 20 s. The bound is loose for
        // a loaded CI machine but far below the linear cost.
        expect(took, lessThan(const Duration(seconds: 1)));
      });
    }

    testWidgets('scrolled deep into 5,000 forged rows, a goodbye of the '
        'first row (every row shifts) builds only the rows on screen', (
      tester,
    ) async {
      await _open(tester, _forged(5000, 0));
      _position(tester).jumpTo(100000);
      await tester.pump();
      final before = _rows;
      expect(before, lessThan(40));
      expect(find.textContaining('Forged '), findsWidgets);
      // Goodbye of row 0 plus a brand new service at the end.
      final churned = [for (var i = 1; i < 5000; i++) _peer(i), _peer(9999)];
      final took = await _change(tester, churned);
      // ignore: avoid_print
      print(
        'R18 probe: deep in 5,000 rows, frame after a goodbye: '
        '${took.inMilliseconds} ms, $_rows rows built',
      );
      expect(_rows, lessThan(40));
      expect(tester.takeException(), isNull);
      expect(took, lessThan(const Duration(seconds: 1)));
    });

    testWidgets('with the semantics tree on (TalkBack), a change in 5,000 '
        'forged rows builds and describes only the rows on screen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _open(tester, _forged(5000, 0));
      final took = await _change(tester, _forged(5000, 1));
      expect(_rows, lessThan(40));
      expect(find.bySemanticsLabel(RegExp('Forged 0 v1')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Forged 4999')), findsNothing);
      expect(took, lessThan(const Duration(seconds: 1)));
      handle.dispose();
    });

    testWidgets('a flood that collapses while scrolled far down leaves a '
        'usable screen', (tester) async {
      await _open(tester, _forged(5000, 0));
      _position(tester).jumpTo(200000);
      await tester.pump();
      await _change(tester, _forged(3, 0));
      // The "Looking" indicator animates while discovering, so the screen
      // never settles: pump past any scroll correction instead.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      _position(tester).jumpTo(0);
      await tester.pump();
      expect(_rows, 3);
      expect(find.text('Forged 2'), findsOneWidget);
    });
  });
}
