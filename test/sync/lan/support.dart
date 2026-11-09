// Fakes for LAN tests: an in-process mDNS "air" (platform channels do not
// exist under flutter test) and a scripted network.
import 'dart:async';
import 'dart:io';

import 'package:settle_up/sync/transport/lan/lan_network.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';

/// Shared mDNS medium: every FakeMdns on the same hub sees the others.
final class FakeMdnsHub {
  final Map<FakeMdns, MdnsAdvert> adverts = {};
  final StreamController<void> _changes = StreamController.broadcast();

  /// Every advertise call made on the hub, in order.
  final List<MdnsAdvert> history = [];

  void _set(FakeMdns who, MdnsAdvert? advert) {
    if (advert == null) {
      if (adverts.remove(who) == null) return;
    } else {
      adverts[who] = advert;
      history.add(advert);
    }
    _changes.add(null);
  }
}

final class FakeMdns implements MdnsBackend {
  FakeMdns(this.hub, {this.address = '127.0.0.1'});

  final FakeMdnsHub hub;

  /// The address this phone's service resolves to.
  final String address;

  int advertiseCalls = 0;
  int stopCalls = 0;
  int activeBrowses = 0;

  MdnsAdvert? get current => hub.adverts[this];

  @override
  Future<void> advertise(MdnsAdvert advert) async {
    advertiseCalls++;
    hub._set(this, advert);
  }

  @override
  Future<void> stopAdvertising() async {
    stopCalls++;
    hub._set(this, null);
  }

  @override
  Stream<(String, MdnsSighting?)> browse() {
    late StreamController<(String, MdnsSighting?)> ctl;
    StreamSubscription<void>? sub;
    var known = <String>{};
    void emit() {
      if (ctl.isClosed) return;
      final now = <String>{};
      for (final e in hub.adverts.entries) {
        final a = e.value;
        now.add(a.name);
        ctl.add((
          a.name,
          MdnsSighting(
            name: a.name,
            addresses: [e.key.address],
            port: a.port,
            attributes: a.attributes,
          ),
        ));
      }
      for (final gone in known.difference(now)) {
        ctl.add((gone, null));
      }
      known = now;
    }

    ctl = StreamController(
      onListen: () {
        activeBrowses++;
        sub = hub._changes.stream.listen((_) => emit());
        scheduleMicrotask(emit);
      },
      onCancel: () async {
        activeBrowses--;
        await sub?.cancel();
      },
    );
    return ctl.stream;
  }
}

/// A network with fixed addresses, gateway and SSID.
final class FakeLanNetwork implements LanNetwork {
  FakeLanNetwork({
    List<LanInterfaceAddress>? addresses,
    this.gateway,
    this.ssid,
  }) : addresses = addresses ??
            [LanInterfaceAddress('lo', InternetAddress.loopbackIPv4)];

  List<LanInterfaceAddress> addresses;
  String? gateway;
  String? ssid;
  int gatewayReads = 0;

  @override
  Future<List<LanInterfaceAddress>> ipv4Addresses() async => addresses;

  @override
  Future<String?> gatewayIp() async {
    gatewayReads++;
    return gateway;
  }

  @override
  Future<String?> wifiName() async => ssid;
}
