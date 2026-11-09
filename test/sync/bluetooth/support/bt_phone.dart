// A phone for Bluetooth end-to-end tests: the real Ledger and a real
// DefaultSyncEngine over one Bluetooth transport running on a fake radio.
import 'dart:async';

import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../support/harness.dart';
import '../../support/phone.dart';

final class BtPhone {
  BtPhone._(this.phone, this.transport, this.engine);

  static Future<BtPhone> create(
    String letter,
    String name,
    SyncTransport transport,
  ) async {
    final phone = await TestPhone.create(letter, deviceName: name);
    final engine = DefaultSyncEngine(
      store: phone.ledger,
      transports: [transport],
      timings: fastTimings,
    );
    return BtPhone._(phone, transport, engine);
  }

  final TestPhone phone;
  final SyncTransport transport;
  final DefaultSyncEngine engine;

  Future<NearbyPeer> find(bool Function(NearbyPeer) match) async {
    if (!engine.status.discovering) await engine.startDiscovery();
    final list = await engine
        .watchNearby()
        .firstWhere((l) => l.any(match))
        .timeout(const Duration(seconds: 5));
    return list.firstWhere(match);
  }

  Future<void> dispose() async {
    await engine.dispose();
    await phone.close();
  }
}

/// Polls [condition] until it holds (or fails the test after [timeout]).
Future<void> pumpUntil(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
