// DATA-R6-01: a peer name that shows nothing (its HELLO, its advert, a
// link) is never shown as a blank name. Property tests over the Unicode
// character classes, not only the reported characters.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/nearby_registry.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

final _letterOrNumber = RegExp(r'^[\p{L}\p{N}]$', unicode: true);

bool _isSurrogate(int r) => r >= 0xD800 && r <= 0xDFFF;

/// Whether [s] holds a letter or number that draws in the compatibility
/// form names are stored and shown in (NFKC, UIFLOW-R6-01): "㉑" is "21"
/// and "ㄱ" is U+1100 there, while U+037A is a space and a lone mark.
bool _drawsName(String s) => unorm.nfkc(s).runes.any(
  (r) =>
      !TextClean.isHidden(r) &&
      !TextClean.isBlankMark(r) &&
      _letterOrNumber.hasMatch(String.fromCharCode(r)),
);

/// Code points that do not make a name: every one that is not a letter or
/// number (spaces, controls, format characters, marks, symbols,
/// punctuation, unassigned), plus the letters that draw as blank space
/// (the Hangul fillers), that hold no such letter or number in NFKC
/// either.
final List<int> nonName = [
  for (var r = 0; r <= 0x10FFFF; r++)
    if (!_isSurrogate(r) &&
        (!_letterOrNumber.hasMatch(String.fromCharCode(r)) ||
            TextClean.isBlankMark(r)) &&
        !_drawsName(String.fromCharCode(r)))
      r,
];

/// Letters and numbers of several scripts that draw.
const List<String> visible = [
  'a',
  'Z',
  '7',
  'ñ',
  'Ж',
  'क',
  '中',
  'ا',
  '๓',
  '가',
  'ㄱ',
  'ß',
  '٣',
  'Ⅻ',
  '\u{20000}',
  '\u{1D400}',
];

String randomFrom(Random rnd, List<int> pool, int maxLen) =>
    String.fromCharCodes([
      for (var i = rnd.nextInt(maxLen) + 1; i > 0; i--)
        pool[rnd.nextInt(pool.length)],
    ]);

void main() {
  test('the reported characters and their classes are in the pool', () {
    for (final r in [
      0x200B,
      0x3164,
      0x2800,
      0x115F,
      0x1160,
      0xFFA0,
      0x00AD,
      0x2060,
      0x200E,
      0x202E,
      0x3000,
      0x00A0,
      0x0301,
      0x2D,
      0x2E,
      0x1F389,
      0xFE0F,
      0xE0001,
      0x09,
      0x0A,
    ]) {
      expect(nonName, contains(r), reason: r.toRadixString(16));
    }
  });

  test('every single code point that is no letter or number is labelled '
      'with the fixed name', () {
    for (final r in nonName) {
      final s = String.fromCharCode(r);
      expect(shownPeerName(s), '', reason: r.toRadixString(16));
      expect(peerLabel([s]), kUnnamedPeer, reason: r.toRadixString(16));
    }
  });

  test('every single letter or number that draws is shown as cleaned', () {
    for (var r = 0; r <= 0x10FFFF; r++) {
      if (_isSurrogate(r) || TextClean.isBlankMark(r)) continue;
      final s = String.fromCharCode(r);
      if (!_letterOrNumber.hasMatch(s) || !_drawsName(s)) continue;
      expect(shownPeerName(s), cleanPeerName(s), reason: r.toRadixString(16));
      expect(shownPeerName(s), isNotEmpty, reason: r.toRadixString(16));
    }
  });

  test('fuzz: a name made only of non-name characters is never shown, and '
      'the label falls through to the next source', () {
    final rnd = Random(7001);
    for (var i = 0; i < 20000; i++) {
      final s = randomFrom(rnd, nonName, 12);
      expect(shownPeerName(s), '', reason: s.runes.toList().toString());
      expect(peerLabel([s, 'Priya']), 'Priya');
      expect(peerLabel([s, s]), kUnnamedPeer);
    }
  });

  test('fuzz: a name with a letter or number among non-name characters is '
      'shown, cleaned and never blank', () {
    final rnd = Random(7002);
    for (var i = 0; i < 20000; i++) {
      final v = visible[rnd.nextInt(visible.length)];
      final s =
          '${randomFrom(rnd, nonName, 6)}$v${randomFrom(rnd, nonName, 6)}';
      final got = shownPeerName(s);
      expect(got, cleanPeerName(s), reason: s.runes.toList().toString());
      // NFKC may change the letter itself ("ㄱ" is U+1100, "Ⅻ" is "XII")
      // or compose it with a following mark, so a letter or number of it
      // is what must be left.
      expect(_drawsName(got), isTrue, reason: s.runes.toList().toString());
      expect(TextRules.isBlank(got), isFalse);
      expect(peerLabel([s, 'Priya']), got);
    }
  });

  test('the label is never blank, whatever the sources', () {
    final rnd = Random(7003);
    final pool = [...nonName.take(5000), ...'aZ7'.runes];
    for (var i = 0; i < 5000; i++) {
      final sources = [
        for (var k = rnd.nextInt(3); k > 0; k--) randomFrom(rnd, pool, 4),
      ];
      final got = peerLabel(sources);
      expect(got, isNotEmpty);
      expect(TextRules.isBlank(got), isFalse, reason: '$sources');
      expect(showsPeerName(got), isTrue);
    }
  });

  group('every place a peer name comes in', () {
    test('the nearby list never shows a blank row', () {
      final r = NearbyRegistry();
      final t0 = DateTime.utc(2026, 11, 10);
      for (final (i, blank) in ['​', 'ㅤ', '⠀', '-', ''].indexed) {
        r.update(
          DiscoveredPeer(
            kind: TransportKind.ble,
            address: 'uuid-$i',
            name: blank,
            advertId: 'aaaa000$i',
          ),
          t0,
        );
      }
      expect(r.peers, hasLength(5));
      for (final p in r.peers) {
        expect(p.name, kUnnamedPeer, reason: p.key);
      }
    });

    test('a nearby row takes the first route name that shows one', () {
      final r = NearbyRegistry();
      final t0 = DateTime.utc(2026, 11, 10);
      r.update(
        const DiscoveredPeer(
          kind: TransportKind.lan,
          address: '10.0.0.2:1',
          name: 'ㅤ',
          advertId: 'aaaa0000',
        ),
        t0,
      );
      r.update(
        const DiscoveredPeer(
          kind: TransportKind.ble,
          address: 'u',
          name: 'Priya',
          advertId: 'aaaa0000',
        ),
        t0,
      );
      expect(r.peers.single.name, 'Priya');
    });

    test('a link name that shows nothing is read as no name', () {
      for (final blank in ['​', 'ㅤ', '⠀', 'ᅟ', '.']) {
        final connect = ConnectLink.tryParse(
          ConnectLink(
            hosts: const ['10.0.0.2:52741'],
            deviceId: 'dddddddd-0000-7000-8000-000000000001',
            deviceName: blank,
          ).encode(),
        )!;
        expect(connect.deviceName, '', reason: blank.runes.toString());
        final invite = InviteLink.tryParse(
          InviteLink(
            groupId: '00000000-0000-7000-9000-000000000001',
            groupKey: Uint8List(32),
            groupName: 'Goa',
            currency: 'INR',
            fromName: blank,
          ).encode(),
        )!;
        // The join prompt then says "Someone".
        expect(invite.fromName, '', reason: blank.runes.toString());
        expect(
          ConnectLink.tryParse(
            ConnectLink(
              hosts: const ['10.0.0.2:52741'],
              deviceId: 'dddddddd-0000-7000-8000-000000000001',
              deviceName: 'Priya$blank',
            ).encode(),
          )!.deviceName,
          cleanPeerName('Priya$blank'),
        );
      }
    });
  });
}
