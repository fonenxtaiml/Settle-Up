// NearbyEndpointName (SPEC 11.3): encode/parse of the advertised endpoint
// name "1|<deviceId[0..8]>|<deviceName <= 24>|<up to 4 tokens>".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

const String deviceId = '0190f2a4-1111-7000-8000-000000000001';

String token(int n) => n.toRadixString(16).padLeft(16, '0');

void main() {
  test('encodes the spec layout', () {
    final name = NearbyEndpointName.of(AdvertiseInfo(
      deviceId: deviceId,
      deviceName: "Alex's Pixel",
      groupTokens: [token(1), token(2)],
    ));
    expect(name.encode(),
        "1|0190f2a4|Alex's Pixel|${token(1)},${token(2)}");
  });

  test('round trips and turns into a DiscoveredPeer', () {
    final encoded = NearbyEndpointName.of(AdvertiseInfo(
      deviceId: deviceId,
      deviceName: 'Priya',
      groupTokens: [token(10)],
    )).encode();
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.version, 1);
    expect(parsed.deviceIdPrefix, '0190f2a4');
    expect(parsed.deviceName, 'Priya');
    expect(parsed.groupTokens, [token(10)]);

    final peer = parsed.toPeer('ABCD');
    expect(peer.kind, TransportKind.nearby);
    expect(peer.address, 'ABCD');
    expect(peer.name, 'Priya');
    expect(peer.deviceIdPrefix, '0190f2a4');
    expect(peer.groupTokens, {token(10)});
  });

  test('keeps at most 4 tokens and drops malformed ones', () {
    final encoded = NearbyEndpointName(
      deviceIdPrefix: '0190f2a4',
      deviceName: 'A',
      groupTokens: [
        'not-a-token',
        for (var i = 0; i < 6; i++) token(i),
        'ABCDEF0123456789', // upper case is not a token
      ],
    ).encode();
    expect(NearbyEndpointName.tryParse(encoded)!.groupTokens,
        [token(0), token(1), token(2), token(3)]);
  });

  test('no tokens leaves the last field empty', () {
    const n = NearbyEndpointName(
      deviceIdPrefix: '0190f2a4',
      deviceName: 'Sam',
      groupTokens: [],
    );
    expect(n.encode(), '1|0190f2a4|Sam|');
    expect(NearbyEndpointName.tryParse(n.encode()), n);
  });

  test('cuts the device name to 24 code points without splitting emoji', () {
    final long = '${'x' * 22}😀😀😀';
    final encoded = NearbyEndpointName(
      deviceIdPrefix: '0190f2a4',
      deviceName: long,
      groupTokens: const [],
    ).encode();
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.deviceName, '${'x' * 22}😀😀');
    expect(parsed.deviceName.runes.length, 24);
  });

  test('stays within the endpoint info byte limit for wide names', () {
    final encoded = NearbyEndpointName(
      deviceIdPrefix: '0190f2a4',
      deviceName: '😀' * 24,
      groupTokens: [for (var i = 0; i < 4; i++) token(i)],
    ).encode();
    expect(utf8.encode(encoded).length,
        lessThanOrEqualTo(NearbyEndpointName.maxBytes));
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.groupTokens, hasLength(4), reason: 'tokens are kept');
    expect(parsed.deviceName, startsWith('😀'));
  });

  test("a '|' in the device name still parses", () {
    final encoded = NearbyEndpointName(
      deviceIdPrefix: '0190f2a4',
      deviceName: 'Home | Kitchen',
      groupTokens: [token(5)],
    ).encode();
    final parsed = NearbyEndpointName.tryParse(encoded)!;
    expect(parsed.deviceName, 'Home | Kitchen');
    expect(parsed.groupTokens, [token(5)]);
  });

  test('a short device id is used as is; an empty one means unknown', () {
    final short = NearbyEndpointName.of(const AdvertiseInfo(
      deviceId: 'abc',
      deviceName: 'X',
      groupTokens: [],
    ));
    expect(short.deviceIdPrefix, 'abc');
    expect(NearbyEndpointName.tryParse('1||Someone|')!.toPeer('E1')
        .deviceIdPrefix, isNull);
  });

  test('a later version with the same leading fields still parses', () {
    final parsed =
        NearbyEndpointName.tryParse('2|0190f2a4|Newer phone|${token(1)}')!;
    expect(parsed.version, 2);
    expect(parsed.deviceName, 'Newer phone');
  });

  test('rejects names that are not ours', () {
    for (final bad in [
      '',
      'Pixel 8',
      '1|abc',
      '1|abc|name',
      'x|abc|name|',
      '0|abc|name|',
      '-1|abc|name|',
    ]) {
      expect(NearbyEndpointName.tryParse(bad), isNull, reason: bad);
    }
  });
}
