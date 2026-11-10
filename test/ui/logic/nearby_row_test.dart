// SYNC-R2-01: a phone in more groups than its advert holds may share one of
// ours even when no token matched. Its row offers Sync (the HELLO decides),
// not Pair.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/screens/sync/sync_screen.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

NearbyPeer peer({
  List<String> shared = const [],
  bool more = false,
  String name = "Priya's Pixel 8",
  Set<TransportKind> transports = const {TransportKind.lan},
}) =>
    NearbyPeer(
      key: 'k',
      name: name,
      transports: transports,
      sharedGroupIds: shared,
      moreGroups: more,
    );

void main() {
  const idle = SessionIdle();
  const names = {'g1': 'Goa trip'};

  test('a phone that shares a group: Sync', () {
    final p = peer(shared: ['g1']);
    expect(nearbyActionOf(p, idle), NearbyPhoneAction.sync);
    expect(phoneKindOf(p), NearbyPhoneKind.android);
    expect(nearbySubtitle(p, names), '${S.wifi}, shares Goa trip');
  });

  test('a phone with no shared group and a full advert: Pair', () {
    final p = peer(transports: {TransportKind.ble});
    expect(p.maySync, isFalse);
    expect(nearbyActionOf(p, idle), NearbyPhoneAction.pair);
    expect(phoneKindOf(p), NearbyPhoneKind.unknown);
    expect(nearbySubtitle(p, names), '${S.bluetooth}, no shared groups');
  });

  test('a phone whose advert was cut: Sync, "may share a group"', () {
    final p = peer(more: true, name: "Ravi's iPhone");
    expect(p.maySync, isTrue);
    expect(nearbyActionOf(p, idle), NearbyPhoneAction.sync);
    expect(phoneKindOf(p), NearbyPhoneKind.iphone);
    expect(nearbySubtitle(p, names), '${S.wifi}, ${S.mayShareGroups}');
  });

  test('a cut advert that still matched names the shared group', () {
    final p = peer(shared: ['g1'], more: true);
    expect(nearbySubtitle(p, names), '${S.wifi}, shares Goa trip');
  });

  test('while a session runs, only that phone shows busy', () {
    const active = SessionActive(SyncProgress(
      peerName: "Priya's Pixel 8",
      transport: TransportKind.lan,
      phase: SyncPhase.transferring,
    ));
    expect(nearbyActionOf(peer(more: true), active), NearbyPhoneAction.busy);
    expect(
      nearbyActionOf(peer(more: true, name: 'Other'), active),
      NearbyPhoneAction.none,
    );
  });
}
