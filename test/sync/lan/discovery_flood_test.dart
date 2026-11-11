// SECURITY-R15-01, end to end: a stranger on the same Wi-Fi announces
// thousands of `_settleup._tcp` services and never says goodbye. The
// sightings run through LanTransport.discover and the engine's registry on
// the UI isolate, and are re-reported every rediscover interval, so both
// must handle a sighting without scanning every other one.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';

import '../support/harness.dart';
import '../support/phone.dart';
import 'support.dart';

/// An mDNS backend whose browse stream carries only what [deliver] sends.
final class _ScriptedMdns implements MdnsBackend {
  final List<StreamController<(String, MdnsSighting?)>> _browses = [];

  @override
  Future<void> advertise(MdnsAdvert advert) async {}
  @override
  Future<void> stopAdvertising() async {}

  @override
  Stream<(String, MdnsSighting?)> browse() {
    late StreamController<(String, MdnsSighting?)> ctl;
    ctl = StreamController(onCancel: () => _browses.remove(ctl));
    _browses.add(ctl);
    return ctl.stream;
  }

  void deliver((String, MdnsSighting?) event) {
    for (final b in _browses) {
      b.add(event);
    }
  }
}

(String, MdnsSighting?) _forged(int i) => (
  'Phone $i',
  MdnsSighting(
    name: 'Phone $i',
    addresses: const ['10.0.0.66'],
    port: 20000 + i,
    attributes: const {'v': '2', 't': ''},
  ),
);

void main() {
  test('2,000 forged services reach the Sync screen quickly, and their '
      're-reports do not stall the isolate', () async {
    const n = 2000;
    final phone = await TestPhone.create('a', deviceName: 'Asha');
    final mdns = _ScriptedMdns();
    final lan = LanTransport(
      port: 0,
      mdns: mdns,
      network: FakeLanNetwork(),
      rediscoverInterval: const Duration(milliseconds: 250),
      probeInterval: const Duration(hours: 1),
    );
    final engine = DefaultSyncEngine(
      store: phone.ledger,
      transports: [lan],
      timings: fastTimings,
    );
    addTearDown(() async {
      await engine.dispose();
      await lan.dispose();
    });
    var listed = 0;
    final sub = engine.watchNearby().listen((p) => listed = p.length);
    addTearDown(sub.cancel);
    await engine.startDiscovery();
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      mdns.deliver(_forged(i));
    }
    while (listed < n && sw.elapsed < const Duration(minutes: 2)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(listed, n);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)),
        reason: 'listing took ${sw.elapsed}');

    // Every 250 ms all of them are re-reported. A 10 ms timer must still
    // fire about on time: the Sync screen keeps drawing frames.
    var worst = Duration.zero;
    final until = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(until)) {
      final t = Stopwatch()..start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (t.elapsed > worst) worst = t.elapsed;
    }
    expect(worst, lessThan(const Duration(milliseconds: 500)),
        reason: 'the isolate stalled for $worst');
    expect(engine.status.discovering, isTrue);
    expect(listed, n);
  });
}
