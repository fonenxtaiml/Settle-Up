// Device names cut to fit HELLO and the adverts keep whole characters
// (DATA-R4-03, DATA-R5-01), and a first character longer than the limit
// is cut by code points rather than sent empty (DATA-R5-02).
import 'dart:convert';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/name_cut.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

bool wellFormed(String s) => utf8.decode(utf8.encode(s)) == s;

bool clusterPrefix(String whole, String cut) =>
    whole.characters.startsWith(cut.characters);

void main() {
  AdvertiseInfo info(String name) => AdvertiseInfo(
    deviceId: 'eeeeeeee-0000-7000-8000-0000000000e9',
    deviceName: name,
    groupTokens: List.generate(30, (i) => 'T${i.toString().padLeft(3, '0')}'),
    advertId: 'a1b2c3d4',
    tokenWindow: 2900000,
  );

  Map<String, String> sent(String name) => {
    'hello': helloDeviceName(name),
    'mdns': MdnsAdvert.serviceNameFor(name),
    'ble': BleInfo.tryParse(BleInfo.of(info(name)).encode())!.deviceName,
    'nearby': NearbyEndpointName.tryParse(
      NearbyEndpointName.of(info(name)).encode(),
    )!.deviceName,
  };

  group('cutName', () {
    test('keeps a name that fits, cuts on character boundaries', () {
      bool units(String s) => s.length <= 5;
      expect(cutName('Pixel', units), 'Pixel');
      expect(cutName('', units), '');
      expect(cutName('a\u{1F1EE}\u{1F1F3}cd', units), 'a\u{1F1EE}\u{1F1F3}');
      expect(cutName('abcd\u{1F1EE}\u{1F1F3}', units), 'abcd');
      expect(cutName('abcde\u0301', units), 'abcd');
    });

    test('a first character longer than the limit: its code points that '
        'fit, never empty, never a lone surrogate', () {
      expect(
        cutName('a${'\u0301' * 10}', (s) => s.length <= 4),
        'a\u0301\u0301\u0301',
      );
      // A cluster of astral code points: a lone surrogate never results.
      final family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      final cut = cutName(family, (s) => s.length <= 4);
      expect(cut, '\u{1F468}\u200D');
      expect(wellFormed(cut), isTrue);
      expect(cutName('\u{1F468}', (s) => s.length <= 1), '');
    });
  });

  group('names as each transport carries them', () {
    test('DATA-R5-01: a flag or conjunct name is cut between characters '
        'on every transport', () {
      for (final name in [
        'a${'\u{1F1EE}\u{1F1F3}' * 26}',
        'क्ष' * 40,
        'क्षि' * 30,
        '${'x' * 39}\u{20000}y',
        'e\u0301' * 40,
      ]) {
        sent(name).forEach((kind, got) {
          expect(wellFormed(got), isTrue, reason: kind);
          expect(clusterPrefix(name, got), isTrue, reason: '$kind: $got');
          expect(got, isNotEmpty, reason: kind);
        });
      }
    });

    test('DATA-R5-02: one character of 101 units is sent as its base '
        'letter and the marks that fit, not as an empty name', () {
      final name = 'a${'\u0301' * 100}';
      sent(name).forEach((kind, got) {
        expect(got, isNotEmpty, reason: kind);
        expect(got.startsWith('a'), isTrue, reason: kind);
        expect(wellFormed(got), isTrue, reason: kind);
      });
      expect(helloDeviceName(name), 'a${'\u0301' * 99}');
    });

    test('limits hold: HELLO 100 units, mDNS 40 units and 63 bytes (a DNS '
        'label), BLE 40 and Nearby 24 code points, Nearby 131 bytes', () {
      final rnd = Random(51);
      const pieces = [
        'a',
        'क्ष',
        'e\u0301',
        '\u{1F1EE}\u{1F1F3}',
        '\u{20000}',
        '\u{1F468}\u200D\u{1F469}',
        'é',
        '|',
      ];
      for (var i = 0; i < 2000; i++) {
        final sb = StringBuffer();
        final n = 1 + rnd.nextInt(60);
        for (var j = 0; j < n; j++) {
          sb.write(pieces[rnd.nextInt(pieces.length)]);
        }
        final name = sb.toString();
        final got = sent(name);
        expect(got['hello']!.length, lessThanOrEqualTo(kMaxDeviceNameLength));
        expect(got['mdns']!.length, lessThanOrEqualTo(kLanServiceNameMax));
        expect(
          utf8.encode(got['mdns']!).length,
          lessThanOrEqualTo(kLanServiceNameMaxBytes),
        );
        expect(
          got['ble']!.runes.length,
          lessThanOrEqualTo(BleInfo.maxNameRunes),
        );
        expect(
          got['nearby']!.runes.length,
          lessThanOrEqualTo(NearbyEndpointName.maxNameRunes),
        );
        expect(
          utf8.encode(NearbyEndpointName.of(info(name)).encode()).length,
          lessThanOrEqualTo(NearbyEndpointName.maxBytes),
        );
        got.forEach((kind, cut) {
          expect(clusterPrefix(name, cut), isTrue, reason: '$kind: $cut');
          expect(cut, isNotEmpty, reason: kind);
          // The longest such prefix: the next character would not fit.
          if (cut != name && kind == 'hello') {
            final next = name.characters.skip(cut.characters.length).first;
            expect(cut.length + next.length, greaterThan(kMaxDeviceNameLength));
          }
        });
      }
    });
  });
}
