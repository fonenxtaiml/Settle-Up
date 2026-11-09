// BleInfo: the INFO characteristic JSON (SPEC 8.7.2).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/ble/ble_chunker.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/transport.dart';

String token(int n) => n.toRadixString(16).padLeft(16, '0');

Uint8List json(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('encodes the spec JSON', () {
    final info = BleInfo.of(AdvertiseInfo(
      deviceId: '0190f2a4-1111-7000-8000-000000000001',
      deviceName: 'Sam iPhone',
      groupTokens: [token(1)],
    ));
    expect(jsonDecode(utf8.decode(info.encode())), {
      'v': 1,
      'd': '0190f2a4',
      'n': 'Sam iPhone',
      't': [token(1)],
    });
  });

  test('round trips into a ble DiscoveredPeer', () {
    final bytes = BleInfo(
      deviceIdPrefix: 'aaaaaaaa',
      deviceName: 'Priya',
      groupTokens: [token(2), token(3)],
    ).encode();
    final peer = BleInfo.tryParse(bytes)!.toPeer('peripheral-uuid');
    expect(peer.kind, TransportKind.ble);
    expect(peer.address, 'peripheral-uuid');
    expect(peer.name, 'Priya');
    expect(peer.deviceIdPrefix, 'aaaaaaaa');
    expect(peer.groupTokens, {token(2), token(3)});
  });

  test('16 tokens and a 40-character wide name fit one attribute', () {
    final bytes = BleInfo(
      deviceIdPrefix: 'aaaaaaaa',
      deviceName: '😀' * 60,
      groupTokens: [for (var i = 0; i < 20; i++) token(i)],
    ).encode();
    expect(bytes.length, lessThanOrEqualTo(kBleMaxAttPayload));
    final parsed = BleInfo.tryParse(bytes)!;
    expect(parsed.deviceName.runes.length, BleInfo.maxNameRunes);
    expect(parsed.groupTokens.length, lessThanOrEqualTo(BleInfo.maxTokens));
    expect(parsed.groupTokens.first, token(0));
  });

  test('parses leniently: extra keys, bad tokens, missing fields', () {
    final parsed = BleInfo.tryParse(json({
      'v': 2,
      'd': 'bbbbbbbb',
      't': [token(1), 7, 'zz', null],
      'x': 'future field',
    }))!;
    expect(parsed.version, 2);
    expect(parsed.deviceName, '');
    expect(parsed.groupTokens, [token(1)]);
    expect(BleInfo.tryParse(json({'v': 1}))!.toPeer('p').deviceIdPrefix,
        isNull);
  });

  test('rejects values that are not INFO', () {
    for (final bad in [
      Uint8List(0),
      Uint8List.fromList([0xff, 0xfe]),
      json([1, 2]),
      json({'d': 'x'}),
      json({'v': 0}),
      json({'v': '1'}),
    ]) {
      expect(BleInfo.tryParse(bad), isNull, reason: '$bad');
    }
  });
}
