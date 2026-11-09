// BleInfo: the INFO characteristic JSON (SPEC 8.7.2).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/ble/ble_chunker.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/transport.dart';

String token(int n) => 'T${n.toRadixString(36).padLeft(3, '0')}';

Uint8List json(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('encodes the spec JSON', () {
    final info = BleInfo.of(AdvertiseInfo(
      deviceId: '0190f2a4-1111-7000-8000-000000000001',
      advertId: '5e1f00d2',
      tokenWindow: 4096 + 0x2b,
      deviceName: 'Sam iPhone',
      groupTokens: [token(1)],
    ));
    expect(jsonDecode(utf8.decode(info.encode())), {
      'v': 2,
      'd': '5e1f00d2',
      'w': '02b',
      'n': 'Sam iPhone',
      't': [token(1)],
    });
  });

  test('never carries the device id', () {
    final bytes = BleInfo.of(const AdvertiseInfo(
      deviceId: '0190f2a4-1111-7000-8000-000000000001',
      deviceName: 'Sam',
      groupTokens: [],
    )).encode();
    expect(utf8.decode(bytes), isNot(contains('0190f2a4')));
  });

  test('round trips into a ble DiscoveredPeer', () {
    final bytes = BleInfo(
      advertId: 'aaaaaaaa',
      deviceName: 'Priya',
      groupTokens: [token(2), token(3)],
      windowTag: 9,
    ).encode();
    final peer = BleInfo.tryParse(bytes)!.toPeer('peripheral-uuid');
    expect(peer.windowTag, 9);
    expect(peer.kind, TransportKind.ble);
    expect(peer.address, 'peripheral-uuid');
    expect(peer.name, 'Priya');
    expect(peer.advertId, 'aaaaaaaa');
    expect(peer.groupTokens, {token(2), token(3)});
  });

  test('48 tokens fit next to a short name', () {
    final bytes = BleInfo(
      advertId: 'aaaaaaaa',
      deviceName: 'Priya',
      groupTokens: [for (var i = 0; i < 60; i++) token(i)],
    ).encode();
    expect(BleInfo.tryParse(bytes)!.groupTokens, hasLength(BleInfo.maxTokens));
  });

  test('tokens and a 40-character wide name fit one attribute', () {
    final bytes = BleInfo(
      advertId: 'aaaaaaaa',
      deviceName: '😀' * 60,
      groupTokens: [for (var i = 0; i < 60; i++) token(i)],
    ).encode();
    expect(bytes.length, lessThanOrEqualTo(kBleMaxAttPayload));
    final parsed = BleInfo.tryParse(bytes)!;
    expect(parsed.deviceName.runes.length, BleInfo.maxNameRunes);
    expect(parsed.groupTokens.length, lessThanOrEqualTo(BleInfo.maxTokens));
    expect(parsed.groupTokens.first, token(0));
  });

  test('parses leniently: extra keys, bad tokens, missing fields', () {
    final parsed = BleInfo.tryParse(json({
      'v': 3,
      'd': 'bbbbbbbb',
      't': [token(1), 7, 'zz', null],
      'x': 'future field',
    }))!;
    expect(parsed.version, 3);
    expect(parsed.advertId, 'bbbbbbbb');
    expect(parsed.deviceName, '');
    expect(parsed.groupTokens, [token(1)]);
    final bare = BleInfo.tryParse(json({'v': 2}))!.toPeer('p');
    expect(bare.advertId, isNull);
    expect(bare.windowTag, isNull);
  });

  test('rejects values that are not INFO', () {
    for (final bad in [
      Uint8List(0),
      Uint8List.fromList([0xff, 0xfe]),
      json([1, 2]),
      json({'d': 'x'}),
      json({'v': 0}),
      json({'v': 1}), // the old format: its tokens cannot match
      json({'v': '2'}),
    ]) {
      expect(BleInfo.tryParse(bad), isNull, reason: '$bad');
    }
  });
}
