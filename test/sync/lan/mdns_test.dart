// mDNS TXT encoding / sighting parsing and interface ordering (SPEC 8.6,
// 8.7.2).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/lan/lan_network.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/transport.dart';

String token(int i) => 'T${i.toRadixString(36).padLeft(3, '0')}';

AdvertiseInfo infoWith(int tokens, {String name = "Priya's Pixel"}) =>
    AdvertiseInfo(
      deviceId: 'abcdef12-0000-7000-8000-000000000001',
      advertId: '5e1f00d2',
      tokenWindow: 2950000,
      deviceName: name,
      groupTokens: [for (var i = 0; i < tokens; i++) token(i)],
    );

void main() {
  group('MdnsAdvert', () {
    test('TXT carries v, the advert id, the window tag and the tokens', () {
      final a = MdnsAdvert.of(infoWith(2), 52741);
      expect(a.port, 52741);
      expect(a.name, "Priya's Pixel");
      expect(a.attributes, {
        'v': '2',
        'd': '5e1f00d2',
        'w': (2950000 % 4096).toRadixString(16).padLeft(3, '0'),
        't': '${token(0)},${token(1)}',
      });
    });

    test('never advertises the device id', () {
      final a = MdnsAdvert.of(infoWith(1), 1);
      expect(a.attributes.values.join(' '), isNot(contains('abcdef12')));
      const noId = AdvertiseInfo(
        deviceId: 'abcdef12-0000-7000-8000-000000000001',
        deviceName: 'x',
        groupTokens: [],
      );
      expect(MdnsAdvert.of(noId, 1).attributes.containsKey('d'), isFalse);
    });

    test('48 tokens fit the t TXT string (<= 255 bytes)', () {
      final a = MdnsAdvert.of(infoWith(60), 1);
      expect(a.attributes['t']!.split(','), hasLength(kLanMaxTokens));
      for (final e in a.attributes.entries) {
        expect(utf8.encode('${e.key}=${e.value}').length, lessThanOrEqualTo(255));
      }
    });

    test('invalid tokens are not advertised', () {
      final a = MdnsAdvert.of(
        const AdvertiseInfo(
          deviceId: 'abcdef12',
          deviceName: 'x',
          groupTokens: ['short', 'ABCDEF0123456789', 'a,bc', 'Qz_-'],
        ),
        1,
      );
      expect(a.attributes['t'], 'Qz_-');
    });

    test('service name: <= 40 chars, never splits an emoji, never empty', () {
      expect(MdnsAdvert.serviceNameFor('  '), 'Settle Up');
      final long = 'A' * 39 + '😀' + 'tail';
      final cut = MdnsAdvert.serviceNameFor(long);
      expect(cut, 'A' * 39);
      expect(MdnsAdvert.serviceNameFor('B' * 60).length, 40);
    });

    test('sameAs compares every field', () {
      final a = MdnsAdvert.of(infoWith(1), 1);
      expect(a.sameAs(MdnsAdvert.of(infoWith(1), 1)), isTrue);
      expect(a.sameAs(MdnsAdvert.of(infoWith(2), 1)), isFalse);
      expect(a.sameAs(MdnsAdvert.of(infoWith(1), 2)), isFalse);
    });
  });

  group('MdnsSighting.toPeer', () {
    MdnsSighting sighting(List<String> addresses,
            {Map<String, String>? attrs, int port = 52741}) =>
        MdnsSighting(
          name: "Priya's Pixel",
          addresses: addresses,
          port: port,
          attributes: attrs ?? MdnsAdvert.of(infoWith(16), port).attributes,
        );

    test('round trips the advert', () {
      final p = sighting(['192.168.1.7']).toPeer()!;
      expect(p.kind, TransportKind.lan);
      expect(p.address, '192.168.1.7:52741');
      expect(p.name, "Priya's Pixel");
      expect(p.advertId, '5e1f00d2');
      expect(p.windowTag, 2950000 % 4096);
      expect(p.groupTokens, {for (var i = 0; i < 16; i++) token(i)});
    });

    test('prefers IPv4, brackets IPv6, strips scope ids', () {
      expect(sighting(['fe80::1%wlan0', '2001:db8::5', '10.0.0.2']).toPeer()!
          .address, '10.0.0.2:52741');
      expect(sighting(['fe80::1%wlan0', '2001:db8::5']).toPeer()!.address,
          '[2001:db8::5]:52741');
      expect(sighting(['127.0.0.1', '10.0.0.9']).toPeer()!.address,
          '10.0.0.9:52741');
    });

    test('rejects foreign services, bad ports and missing addresses', () {
      expect(sighting(['10.0.0.2'], attrs: {'v': '1'}).toPeer(), isNull);
      expect(sighting(['10.0.0.2'], attrs: {}).toPeer(), isNull);
      expect(sighting([]).toPeer(), isNull);
      expect(sighting(['nonsense']).toPeer(), isNull);
      expect(sighting(['10.0.0.2'], port: 0).toPeer(), isNull);
    });

    test('missing d means unknown device; junk tokens are dropped', () {
      final p = sighting(['10.0.0.2'],
          attrs: {'v': '2', 't': 'zz,${token(3)},', 'w': 'xyz'}).toPeer()!;
      expect(p.advertId, isNull);
      expect(p.windowTag, isNull);
      expect(p.groupTokens, {token(3)});
    });

    test('a later version with the same keys still parses', () {
      expect(sighting(['10.0.0.2'], attrs: {'v': '3'}).toPeer(), isNotNull);
    });
  });

  group('interface ordering', () {
    LanInterfaceAddress a(String name, String ip) =>
        LanInterfaceAddress(name, InternetAddress(ip));

    test('hotspot first, then Wi-Fi, then others; cellular/VPN dropped', () {
      final ordered = orderAddresses([
        a('rmnet_data0', '100.64.1.2'),
        a('wlan0', '192.168.1.5'),
        a('tun0', '10.8.0.2'),
        a('usb0', '192.168.42.1'),
        a('swlan0', '10.33.1.1'),
        a('lo', '127.0.0.1'),
        a('ap0', '192.168.77.1'),
        a('wlan1', '192.168.49.1'),
        a('bridge100', '172.20.10.1'),
        a('en0', '172.20.10.3'),
        a('pdp_ip0', '10.20.30.40'),
        a('wlan0', '169.254.3.3'),
      ]);
      expect(ordered.map((x) => x.interfaceName), [
        'swlan0',
        'ap0',
        'wlan1',
        'bridge100',
        'wlan0',
        'en0',
        'usb0',
      ]);
    });

    test('IPv6 addresses are not listed', () {
      expect(orderAddresses([a('wlan0', 'fe80::1'), a('wlan0', '2001:db8::1')]),
          isEmpty);
    });

    test('cleanWifiName', () {
      expect(cleanWifiName('"Goa house"'), 'Goa house');
      expect(cleanWifiName('Cafe'), 'Cafe');
      expect(cleanWifiName('<unknown ssid>'), isNull);
      expect(cleanWifiName('""'), isNull);
      expect(cleanWifiName(null), isNull);
    });
  });
}
