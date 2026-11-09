import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/pairing/links.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
  const g = '0190f3a4-1b2c-7d3e-8f40-123456789abc';
  const d = '0190f3a4-0000-7000-8000-000000000001';

  group('InviteLink', () {
    test('round trips with and without the optional fields', () {
      for (final link in [
        InviteLink(
          groupId: g,
          groupKey: key,
          groupName: 'Goa trip & more = fun?',
          currency: 'INR',
          fromName: "Alex's Pixel 7",
          host: '192.168.43.1:52741',
          deviceId: d,
        ),
        InviteLink(
          groupId: g,
          groupKey: key,
          groupName: 'Flat',
          currency: 'GBP',
          fromName: '',
        ),
      ]) {
        final s = link.encode();
        expect(s, startsWith('settleup://join?v=1&'));
        expect(s, isNot(contains('=&')), reason: 'no empty padding');
        final back = InviteLink.tryParse(s)!;
        expect(back.groupId, link.groupId);
        expect(back.groupKey, link.groupKey);
        expect(back.groupName, link.groupName);
        expect(back.currency, link.currency);
        expect(back.fromName, link.fromName);
        expect(back.host, link.host);
        expect(back.deviceId, link.deviceId);
        // Surrounding whitespace from a paste is fine.
        expect(InviteLink.tryParse('  $s\n')?.groupId, g);
      }
    });

    test('the key is base64url without padding', () {
      final s = InviteLink(
              groupId: g, groupKey: key, groupName: 'x', currency: 'INR',
              fromName: 'a')
          .encode();
      final k = Uri.parse(s).queryParameters['k']!;
      expect(k, hasLength(43));
      expect(k, isNot(contains('=')));
      expect(k, isNot(contains('+')));
      expect(k, isNot(contains('/')));
    });

    test('bad links parse to null', () {
      final good = InviteLink(
              groupId: g, groupKey: key, groupName: 'x', currency: 'INR',
              fromName: 'a')
          .encode();
      String without(String param) {
        final uri = Uri.parse(good);
        final q = Map.of(uri.queryParameters)..remove(param);
        return uri.replace(queryParameters: q).toString();
      }

      String with_(String param, String value) {
        final uri = Uri.parse(good);
        return uri
            .replace(queryParameters: {...uri.queryParameters, param: value})
            .toString();
      }

      for (final bad in [
        '',
        'hello',
        'https://join?v=1',
        good.replaceFirst('settleup://join', 'settleup://sync'),
        good.replaceFirst('settleup:', 'settledown:'),
        with_('v', '2'),
        without('v'),
        without('g'),
        without('k'),
        without('n'),
        without('c'),
        with_('k', 'AAAA'), // 3 bytes
        with_('k', '${'A' * 42}*'), // not base64url
        with_('k', 'A' * 45), // 33 bytes
      ]) {
        expect(InviteLink.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('ConnectLink', () {
    test('round trips several hosts in order, IPv6 included', () {
      const link = ConnectLink(
        hosts: ['192.168.43.1:52741', '10.0.0.5:52741', '[fe80::1]:52741'],
        deviceId: d,
        deviceName: "Priya's Pixel 8 & co",
      );
      final s = link.encode();
      expect(s, startsWith('settleup://sync?v=1&h='));
      final back = ConnectLink.tryParse(s)!;
      expect(back.hosts, link.hosts);
      expect(back.deviceId, d);
      expect(back.deviceName, link.deviceName);
    });

    test('bad links parse to null', () {
      const good = ConnectLink(
          hosts: ['1.2.3.4:5'], deviceId: d, deviceName: 'x');
      final s = good.encode();
      for (final bad in [
        'settleup://sync?v=1&d=$d', // no hosts
        'settleup://sync?v=1&h=1.2.3.4:5', // no device id
        s.replaceFirst('v=1', 'v=2'),
        s.replaceFirst('v=1&', ''),
        s.replaceFirst('settleup://sync', 'settleup://join'),
        s.replaceFirst('settleup', 'http'),
        'not a link',
      ]) {
        expect(ConnectLink.tryParse(bad), isNull, reason: bad);
      }
      expect(ConnectLink.tryParse('settleup://sync?v=1&h=a:1&d=$d')!.deviceName,
          '');
    });

    test('an invite is not a connect link and vice versa', () {
      final invite = InviteLink(
              groupId: g, groupKey: key, groupName: 'x', currency: 'INR',
              fromName: 'a', host: '1.2.3.4:5')
          .encode();
      expect(ConnectLink.tryParse(invite), isNull);
      expect(
          InviteLink.tryParse(const ConnectLink(
                  hosts: ['1.2.3.4:5'], deviceId: d, deviceName: 'x')
              .encode()),
          isNull);
    });
  });
}
