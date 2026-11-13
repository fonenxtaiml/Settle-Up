// QA SECURITY round 17: SECURITY-R17-02.
//
// test/sync/crypto_test.dart "HELLOs carry no group ids in clear and blind
// per nonce" checks that the HELLO frame text does not contain the group
// id 'g1'. The HELLO also carries the ephemeral X25519 public key, which
// Handshake.start always draws from a secure random source (the test's
// seeded Random only drives the nonce), as 43 base64url characters. Those
// contain "g1" about once in a hundred runs, and the full suite then fails
// with no defect in the product (seen in round 17: eph
// "yOvD_nfBH0dpAnsoOiVElqIgdbqUpwMcO3J10qg1D1E"). The guard must check
// for the group id where it could leak (the groups list, any decoded
// field) or use a group id that base64url cannot spell.
//
// Fixed: crypto_test now uses helloGroupIdLeaks (test/sync/support/
// hello_leak.dart), which decodes the frame, checks the opaque fields as
// bytes and the rest of the frame as text. This repro runs that guard.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/crypto/handshake.dart';

import '../../sync/support/hello_leak.dart';
import '../../sync/support/phone.dart';

void main() {
  test('the crypto_test HELLO guard never trips on random key bytes', () async {
    var hits = 0;
    for (var i = 0; i < 1500; i++) {
      final h = await Handshake.start(
        initiator: true,
        groupKeys: {'g1': groupKeyOf(1)},
        deviceId: 'dev-0000',
        deviceName: 'dev',
        maxFrame: 16384,
        transport: TransportKind.lan,
        random: Random(1),
      );
      if (helloGroupIdLeaks(h.helloFrame, 'g1').isNotEmpty) hits++;
    }
    expect(hits, 0, reason: '$hits of 1500 HELLOs "contain" g1');
  });
}
