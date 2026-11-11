// The HELLO group id guard (support/hello_leak.dart, SECURITY-R17-02):
// silent on random opaque bytes, loud on every real leak.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';

import 'support/hello_leak.dart';
import 'support/phone.dart';

Uint8List _b64(String s) => base64Url.decode(base64Url.normalize(s));

Uint8List _bytes(Random r, int n) =>
    Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));

HelloMessage _hello({
  required Uint8List eph,
  required Uint8List nonce,
  required List<Uint8List> groups,
  String deviceId = 'dev-0000',
  String deviceName = 'dev',
}) => HelloMessage(
  deviceId: deviceId,
  deviceName: deviceName,
  ephemeralPublicKey: eph,
  nonce: nonce,
  blindedGroups: groups,
  maxFrame: 16384,
  transport: TransportKind.lan,
);

const _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

void main() {
  test('the round-17 failing HELLO: raw text has g1, the guard is clean', () {
    final frame = FrameCodec.plainFrame(
      _hello(
        eph: _b64('yOvD_nfBH0dpAnsoOiVElqIgdbqUpwMcO3J10qg1D1E'),
        nonce: Uint8List(16),
        groups: [_b64('awhYPGlLTFwa3-xcwvy7bg')],
      ),
    );
    expect(String.fromCharCodes(frame), contains('g1'));
    expect(helloGroupIdLeaks(frame, 'g1'), isEmpty);
  });

  test('random opaque bytes never trip the guard (seeded fuzz)', () {
    final r = Random(1702);
    final ids = ['g1', 'G1', 'gg', groupIdOf(1), 'awhYPGlLTFwa3-xcwvy7bg'];
    for (var i = 0; i < 3000; i++) {
      final frame = FrameCodec.plainFrame(
        _hello(
          eph: _bytes(r, 32),
          nonce: _bytes(r, 16),
          groups: List.generate(1 + r.nextInt(8), (_) => _bytes(r, 16)),
        ),
      );
      for (final id in ids) {
        expect(helloGroupIdLeaks(frame, id), isEmpty, reason: '$i $id');
      }
    }
  });

  test('real HELLOs from Handshake.start never trip the guard', () async {
    for (var i = 0; i < 300; i++) {
      final h = await Handshake.start(
        initiator: i.isEven,
        groupKeys: {'g1': groupKeyOf(1), groupIdOf(2): groupKeyOf(2)},
        deviceId: 'dev-0000',
        deviceName: 'dev',
        maxFrame: 16384,
        transport: TransportKind.lan,
        random: Random(i),
      );
      expect(helloGroupIdLeaks(h.helloFrame, 'g1'), isEmpty);
      expect(helloGroupIdLeaks(h.helloFrame, groupIdOf(2)), isEmpty);
    }
  });

  test('an id anywhere in the clear fields is caught (seeded fuzz)', () {
    final r = Random(17);
    for (var i = 0; i < 500; i++) {
      final id = String.fromCharCodes(
        List.generate(
          2 + r.nextInt(20),
          (_) => _alphabet.codeUnitAt(r.nextInt(_alphabet.length)),
        ),
      );
      final at = r.nextInt(4);
      final name = 'x' * at + id + 'y' * r.nextInt(4);
      final frame = FrameCodec.plainFrame(
        _hello(
          eph: _bytes(r, 32),
          nonce: _bytes(r, 16),
          groups: [_bytes(r, 16)],
          deviceName: name,
        ),
      );
      expect(helloGroupIdLeaks(frame, id), isNotEmpty, reason: name);
    }
  });

  test('an id in the device id is caught', () {
    final id = groupIdOf(7);
    final frame = FrameCodec.plainFrame(
      _hello(
        eph: Uint8List(32),
        nonce: Uint8List(16),
        groups: [Uint8List(16)],
        deviceId: id,
      ),
    );
    expect(helloGroupIdLeaks(frame, id), isNotEmpty);
  });

  test('an id carried as bytes in a blinded group slot is caught', () {
    const text = 'abcdefghijklmnop'; // 16 UTF-8 bytes
    final uuid = groupIdOf(9);
    final uuidBytes = Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(uuid.replaceAll('-', '').substring(i, i + 2), radix: 16),
    ]);
    final b64Id = base64Url
        .encode(List.generate(16, (i) => i * 7))
        .replaceAll('=', '');
    for (final (id, bytes) in [
      (text, Uint8List.fromList(utf8.encode(text))),
      (uuid, uuidBytes),
      (b64Id, _b64(b64Id)),
    ]) {
      final frame = FrameCodec.plainFrame(
        _hello(eph: Uint8List(32), nonce: Uint8List(16), groups: [bytes]),
      );
      expect(helloGroupIdLeaks(frame, id), isNotEmpty, reason: id);
    }
  });

  test('a leak inside a gzipped HELLO body is caught', () {
    final r = Random(5);
    final frame = FrameCodec.plainFrame(
      _hello(
        eph: _bytes(r, 32),
        nonce: _bytes(r, 16),
        groups: List.generate(200, (_) => _bytes(r, 16)),
        deviceName: 'phone ${groupIdOf(3)}',
      ),
    );
    expect(frame[2] & kFlagGzip, kFlagGzip);
    expect(String.fromCharCodes(frame), isNot(contains(groupIdOf(3))));
    expect(helloGroupIdLeaks(frame, groupIdOf(3)), isNotEmpty);
  });
}
