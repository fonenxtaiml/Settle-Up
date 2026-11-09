// NearbyEndpointName (SPEC 8.7.2): encode/parse of the advertised endpoint
// name "2|<advertId>|<windowTag>|<deviceName <= 24>|<up to 24 tokens>".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

const String deviceId = '0190f2a4-1111-7000-8000-000000000001';

String token(int n) => 'T${n.toRadixString(36).padLeft(3, '0')}';

void main() {
  test('encodes the spec layout', () {
    final name = NearbyEndpointName.of(AdvertiseInfo(
      deviceId: deviceId,
      advertId: '5e1f00d2',
      tokenWindow: 4096 * 700 + 0xa3c,
      deviceName: "Alex's Pixel",
      groupTokens: [token(1), token(2)],
    ));
    expect(name.encode(), "2|5e1f00d2|a3c|Alex's Pixel|${token(1)}${token(2)}");
  });

  test('never carries the device id', () {
    final encoded = NearbyEndpointName.of(const AdvertiseInfo(
      deviceId: deviceId,
      deviceName: 'X',
      groupTokens: [],
    )).encode();
    expect(encoded, '2|||X|');
    expect(encoded, isNot(contains('0190f2a4')));
  });

  test('round trips and turns into a DiscoveredPeer', () {
    final encoded = NearbyEndpointName.of(AdvertiseInfo(
      deviceId: deviceId,
      advertId: '5e1f00d2',
      tokenWindow: 17,
      deviceName: 'Priya',
      groupTokens: [token(10)],
    )).encode();
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.version, 2);
    expect(parsed.advertId, '5e1f00d2');
    expect(parsed.windowTag, 17);
    expect(parsed.deviceName, 'Priya');
    expect(parsed.groupTokens, [token(10)]);

    final peer = parsed.toPeer('ABCD');
    expect(peer.kind, TransportKind.nearby);
    expect(peer.address, 'ABCD');
    expect(peer.name, 'Priya');
    expect(peer.advertId, '5e1f00d2');
    expect(peer.windowTag, 17);
    expect(peer.groupTokens, {token(10)});
  });

  test('keeps at most 24 tokens and drops malformed ones', () {
    final encoded = NearbyEndpointName(
      advertId: '5e1f00d2',
      deviceName: 'A',
      groupTokens: [
        'not-a-token',
        for (var i = 0; i < 30; i++) token(i),
        'a|b,', // separators are not token characters
      ],
    ).encode();
    expect(NearbyEndpointName.tryParse(encoded)!.groupTokens,
        [for (var i = 0; i < 24; i++) token(i)]);
  });

  test('no tokens leaves the last field empty', () {
    const n = NearbyEndpointName(
      advertId: '5e1f00d2',
      deviceName: 'Sam',
      groupTokens: [],
      windowTag: 1,
    );
    expect(n.encode(), '2|5e1f00d2|001|Sam|');
    expect(NearbyEndpointName.tryParse(n.encode()), n);
  });

  test('cuts the device name to 24 code points without splitting emoji', () {
    final long = '${'x' * 22}😀😀😀';
    final encoded = NearbyEndpointName(
      advertId: '5e1f00d2',
      deviceName: long,
      groupTokens: const [],
    ).encode();
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.deviceName, '${'x' * 22}😀😀');
    expect(parsed.deviceName.runes.length, 24);
  });

  test('24 tokens and a wide name stay within the endpoint info limit', () {
    final encoded = NearbyEndpointName(
      advertId: '5e1f00d2',
      windowTag: 4095,
      deviceName: '😀' * 24,
      groupTokens: [for (var i = 0; i < 24; i++) token(i)],
    ).encode();
    expect(utf8.encode(encoded).length,
        lessThanOrEqualTo(NearbyEndpointName.maxBytes));
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.groupTokens, hasLength(24), reason: 'tokens are kept');
    expect(parsed.deviceName, startsWith('😀'));
  });

  test("a '|' in the device name still parses", () {
    final encoded = NearbyEndpointName(
      advertId: '5e1f00d2',
      deviceName: 'Home | Kitchen',
      groupTokens: [token(5)],
    ).encode();
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.deviceName, 'Home | Kitchen');
    expect(parsed.groupTokens, [token(5)]);
  });

  test('a bad advert id or window tag means unknown', () {
    final parsed = NearbyEndpointName.tryParse('2|xyz|zz|Someone|')!;
    expect(parsed.toPeer('E1').advertId, isNull);
    expect(parsed.toPeer('E1').windowTag, isNull);
  });

  test('a later version with the same leading fields still parses', () {
    final parsed = NearbyEndpointName.tryParse(
        '3|5e1f00d2|001|Newer phone|${token(1)}')!;
    expect(parsed.version, 3);
    expect(parsed.deviceName, 'Newer phone');
    expect(parsed.groupTokens, [token(1)]);
  });

  test('rejects names that are not ours', () {
    for (final bad in [
      '',
      'Pixel 8',
      '2|abc',
      '2|abc|001|name',
      'x|abc|001|name|',
      '0|abc|001|name|',
      '-1|abc|001|name|',
      // The old layout (16-hex tokens) cannot be matched any more.
      '1|0190f2a4|Old phone|0123456789abcdef',
    ]) {
      expect(NearbyEndpointName.tryParse(bad), isNull, reason: bad);
    }
  });
}
