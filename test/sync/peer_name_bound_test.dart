// SECURITY-R15-02: a peer's name (link n and f values, HELLO, adverts) is
// cut to kMaxPeerNameUnits code units before it is normalised, so a hostile
// settleup:// link of any size and shape parses in milliseconds, and every
// name this app puts in a link survives the cut.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';

final Uint8List _key = Uint8List.fromList(List.generate(32, (i) => i));
const String _keyB64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

Duration _time(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  return sw.elapsed;
}

String _alt(int n) => List.generate(n, (i) => i.isEven ? '́' : '̖').join();

/// Hostile names of about [units] code units, one per shape: plain text,
/// CJK, one run of marks, short runs split by invisibles, runs of
/// NFKD-mark characters, compatibility characters that grow under NFKC.
Map<String, String> _hostile(int units) => {
  'ascii': 'A' * units,
  'cjk': String.fromCharCodes(List.generate(units, (i) => 0x4E00 + i % 20000)),
  'one run of marks': 'A${_alt(units)}',
  'runs split by ZWSP': 'A${'${_alt(250)}​' * (units ~/ 251)}',
  'halfwidth voiced marks': 'A${'ﾞ' * units}',
  'NFKC grows': 'ﷺ' * units,
  'invisibles only, then a name': '${'​' * units}Asha',
  'emoji sequences': '\u{1F468}‍\u{1F469}‍\u{1F467}' * (units ~/ 8),
};

void main() {
  const budget = Duration(milliseconds: 500);

  test('boundPeerName keeps short names and never splits a surrogate', () {
    expect(boundPeerName('Asha'), 'Asha');
    final exact = 'a' * kMaxPeerNameUnits;
    expect(boundPeerName(exact), exact);
    expect(boundPeerName('${exact}b'), exact);
    // A pair across the cut is left out whole.
    final across = '${'a' * (kMaxPeerNameUnits - 1)}\u{1F600}';
    expect(boundPeerName(across), 'a' * (kMaxPeerNameUnits - 1));
    final rnd = Random(15);
    for (var i = 0; i < 500; i++) {
      final s = String.fromCharCodes(
        List.generate(
          kMaxPeerNameUnits + rnd.nextInt(40) - 20,
          (_) => rnd.nextBool() ? 0x61 : 0x1F600,
        ),
      );
      final b = boundPeerName(s);
      expect(b.length, lessThanOrEqualTo(kMaxPeerNameUnits));
      expect(s.startsWith(b), isTrue);
      // Well formed: no lone surrogate at the end.
      final last = b.isEmpty ? 0 : b.codeUnitAt(b.length - 1);
      expect(last >= 0xD800 && last <= 0xDBFF, isFalse);
    }
  });

  test('every name this phone can save reads back the same after the cut', () {
    // Names are saved fit to their limit (at most 240 code units), and a
    // saved name is its own clean form.
    final rnd = Random(1602);
    const pieces = [
      'a',
      'Ä',
      '́',
      ' ',
      'प्रि',
      '\u{1F469}‍\u{1F4BB}',
      '\u{20000}',
      'ﷺ',
      'ㅤ',
    ];
    for (var i = 0; i < 400; i++) {
      final raw = List.generate(
        1 + rnd.nextInt(120),
        (_) => pieces[rnd.nextInt(pieces.length)],
      ).join();
      for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
        final saved = NameText.fit(raw, limit);
        expect(cleanPeerName(saved), saved, reason: raw);
        expect(boundPeerName(saved), saved);
      }
      final link = InviteLink(
        groupId: 'g1',
        groupKey: _key,
        groupName: NameText.fit(raw, NameText.maxGroupLength),
        currency: 'INR',
        fromName: NameText.fit(raw),
      );
      final back = InviteLink.tryParse(link.encode())!;
      expect(back.groupName, link.groupName);
      expect(back.fromName, shownPeerName(link.fromName));
      final c = ConnectLink(
        hosts: const ['192.168.43.1:52741'],
        deviceId: 'dev1',
        deviceName: NameText.fit(raw),
      );
      expect(
        ConnectLink.tryParse(c.encode())!.deviceName,
        shownPeerName(c.deviceName),
      );
    }
  });

  group('a hostile link name of any shape parses fast', () {
    // About 1 MB of URL once percent-encoded, the most an Android intent
    // carries.
    _hostile(120000).forEach((shape, name) {
      test(shape, () {
        final enc = Uri.encodeQueryComponent(name);
        final invites = [
          'settleup://join?v=1&g=g1&k=$_keyB64&c=INR&n=$enc&f=Asha',
          'settleup://join?v=1&g=g1&k=$_keyB64&c=INR&n=Trip&f=$enc',
        ];
        for (final link in invites) {
          InviteLink? parsed;
          final took = _time(() => parsed = InviteLink.tryParse(link));
          expect(parsed, isNotNull);
          expect(took, lessThan(budget), reason: '${took.inMilliseconds} ms');
          expect(
            parsed!.groupName.length,
            lessThanOrEqualTo(kMaxPeerNameUnits * 18),
          );
        }
        final connect =
            'settleup://sync?v=1&h=192.168.43.1:52741&d=dev1&n=$enc';
        ConnectLink? parsed;
        final took = _time(() => parsed = ConnectLink.tryParse(connect));
        expect(parsed, isNotNull);
        expect(took, lessThan(budget), reason: '${took.inMilliseconds} ms');
        // What is shown of it reads fast as well.
        final shown = _time(() => peerLabel([parsed!.deviceName, name]));
        expect(shown, lessThan(budget), reason: '${shown.inMilliseconds} ms');
      });
    });
  });

  test('shownPeerName and peerLabel read any raw name in bounded time', () {
    for (final name in _hostile(400000).values) {
      final took = _time(() {
        shownPeerName(name);
        peerLabel([name]);
      });
      expect(took, lessThan(budget), reason: '${took.inMilliseconds} ms');
    }
  });
}
