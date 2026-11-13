// The Sync screen builds its nearby phones lazily (SECURITY-R17-01): a
// stranger who announces thousands of services gets a frame cost that does
// not grow with their number, and every phone stays reachable by
// scrolling, the ones that share a group first.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/list_section.dart';
import 'package:settle_up/ui/widgets/nearby.dart';

import 'screen_harness.dart';

List<NearbyPeer> _forged(int n, int gen, {String? shared}) => [
  if (shared != null)
    NearbyPeer(
      key: 'lan|10.0.0.5:4000',
      name: 'Priya phone',
      transports: const {TransportKind.lan},
      sharedGroupIds: [shared],
    ),
  for (var i = 0; i < n; i++)
    NearbyPeer(
      key: 'lan|10.0.0.66:${20000 + i}',
      name: i == 0 ? 'Forged $i v$gen' : 'Forged $i',
      transports: const {TransportKind.lan},
      sharedGroupIds: const [],
    ),
];

int get _rows => find.byType(NearbyPhoneRow).evaluate().length;

void main() {
  for (final n in const [50, 500, 5000]) {
    testWidgets('$n forged phones: a change of one row builds only the rows '
        'on screen', (tester) async {
      phoneView(tester);
      final world = await TestWorld.demo();
      await pumpApp(tester, world, location: Routes.sync);
      world.engine.emitNearby(_forged(n, 0));
      await tester.pump();
      await tester.pump();
      final first = _rows;
      world.engine.emitNearby(_forged(n, 1));
      await tester.pump();
      await tester.pump();
      expect(_rows, lessThan(40));
      expect(_rows, first);
      expect(find.text('Forged 0 v1'), findsOneWidget);
    });
  }

  testWidgets('the phone that shares a group is listed first and every '
      'forged one can still be scrolled to', (tester) async {
    phoneView(tester);
    final world = await TestWorld.demo();
    await pumpApp(tester, world, location: Routes.sync);
    world.engine.emitNearby(_forged(300, 0, shared: world.g.goa));
    await tester.pump();
    await tester.pump();
    final rows = find.byType(NearbyPhoneRow);
    expect(tester.widget<NearbyPhoneRow>(rows.first).name, 'Priya phone');
    await tester.scrollUntilVisible(
      find.text('Forged 299'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Forged 299'), findsOneWidget);
    expect(_rows, lessThan(40));
  });

  testWidgets('a short list draws as one card: rounded at its ends, '
      'hairlines between the rows', (tester) async {
    phoneView(tester);
    final world = await TestWorld.demo();
    await pumpApp(tester, world, location: Routes.sync);
    world.engine.emitNearby(_forged(3, 0));
    await tester.pump();
    await tester.pump();
    expect(_rows, 3);
    final cards = find.descendant(
      of: find.byType(SliverListSection),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.shape is RoundedRectangleBorder,
      ),
    );
    final radii = [
      for (final e in cards.evaluate())
        ((e.widget as Material).shape! as RoundedRectangleBorder).borderRadius
            as BorderRadius,
    ];
    expect(radii, hasLength(3));
    expect(radii.first.topLeft, isNot(Radius.zero));
    expect(radii.first.bottomLeft, Radius.zero);
    expect(radii[1], BorderRadius.zero);
    expect(radii.last.topLeft, Radius.zero);
    expect(radii.last.bottomLeft, isNot(Radius.zero));
    expect(
      find.descendant(
        of: find.byType(SliverListSection),
        matching: find.byType(Divider),
      ),
      findsNWidgets(2),
    );
  });
}
