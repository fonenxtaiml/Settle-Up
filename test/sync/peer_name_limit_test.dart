// SECURITY-R39-01: every name another phone sends (HELLO, advert, connect
// link `n`, invite link `f` and `n`) is shown and recorded at no more than
// the limit of a name typed on a phone: 40 characters for a phone name, 60
// for a group name (SPEC 5.16). Sync history and Activity wrap a phone name
// in full (VISUAL-R36-01), so a longer one would fill the screen.
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/codecs.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';

const String _keyB64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

/// Code points of the classes a name can hold: letters of several
/// scripts, digits, emoji and sequences, combining marks, characters NFKC
/// grows, every kind of space, format and invisible filler, punctuation.
const List<List<int>> _classes = [
  [0x41, 0x5A], // Latin capitals
  [0x61, 0x7A], // Latin small
  [0x30, 0x39], // digits
  [0x0905, 0x0939], // Devanagari letters
  [0x093E, 0x094D], // Devanagari vowel signs and virama
  [0x4E00, 0x4E80], // CJK
  [0xAC00, 0xAC80], // Hangul syllables
  [0x0300, 0x036F], // combining marks
  [0x1F600, 0x1F64F], // emoji
  [0x1F3FB, 0x1F3FF], // skin tones
  [0x1F1E6, 0x1F1FF], // regional indicators
  [0xFDFA, 0xFDFB], // NFKC grows 18x
  [0x3380, 0x33FF], // squared compatibility words
  [0x2000, 0x200F], // spaces, zero-width and marks
  [0x2028, 0x202F], // separators, bidi embeddings
  [0x2060, 0x206F], // word joiner, invisible operators, bidi isolates
  [0x3164, 0x3164], // Hangul filler
  [0x115F, 0x1160], // Hangul choseong/jungseong fillers
  [0xFFA0, 0xFFA0], // halfwidth Hangul filler
  [0x2800, 0x2800], // braille blank
  [0x00AD, 0x00AD], // soft hyphen
  [0xFE00, 0xFE0F], // variation selectors
  [0x20, 0x2F], // space and punctuation
  [0x09, 0x0D], // tabs and line breaks
];

String _randomName(Random rnd, int maxCodePoints) {
  final n = rnd.nextInt(maxCodePoints + 1);
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    final c = _classes[rnd.nextInt(_classes.length)];
    out.writeCharCode(c[0] + rnd.nextInt(c[1] - c[0] + 1));
  }
  return out.toString();
}

void _expectPhoneName(String shown, String raw) {
  expect(
    NameText.fits(shown, NameText.maxLength),
    isTrue,
    reason:
        '${shown.characters.length} characters, ${shown.length} units '
        'from ${raw.runes.map((r) => r.toRadixString(16)).join(' ')}',
  );
}

void main() {
  test('fuzz: a shown peer name fits a phone name, is what this phone saves '
      'of it, and is stable', () {
    final rnd = Random(3901);
    for (var i = 0; i < 3000; i++) {
      final raw = _randomName(rnd, i.isEven ? 60 : 1200);
      final shown = shownPeerName(raw);
      _expectPhoneName(shown, raw);
      expect(shownPeerName(shown), shown, reason: 'stable');
      if (shown.isNotEmpty) {
        expect(showsPeerName(shown), isTrue);
        expect(shown, NameText.fit(boundPeerName(raw)));
      }
      // The label (nearby list, session, history) is never blank or long.
      final label = peerLabel([raw]);
      expect(label, isNotEmpty);
      _expectPhoneName(label, raw);
    }
  });

  test('a name a phone may save is shown unchanged', () {
    final rnd = Random(3902);
    var checked = 0;
    for (var i = 0; i < 3000; i++) {
      final saved = NameText.fit(_randomName(rnd, 50));
      if (!NameText.isValid(saved)) continue;
      checked++;
      expect(shownPeerName(saved), saved);
    }
    expect(checked, greaterThan(500));
    for (final name in [
      "Alex's Pixel",
      'Priya’s Galaxy S24 Ultra 5G (work phone)',
      'A' * NameText.maxLength,
      'Ravi \u{1F468}\u200D\u{1F469}\u200D\u{1F467} \u{1F1EE}\u{1F1F3}',
      'संदीप का फ़ोन',
    ]) {
      expect(shownPeerName(name), name);
    }
  });

  test('a long name is cut to its first 40 characters', () {
    final hostile = List.filled(200, 'Pixel').join(' ');
    final shown = shownPeerName(hostile);
    expect(shown, hostile.substring(0, NameText.maxLength).trim());
    expect(
      shownPeerName('${'B' * 39}${'\u{1F600}' * 50}'),
      '${'B' * 39}\u{1F600}',
    );
    // A name whose only letter is past the limit shows nothing.
    expect(shownPeerName('${'.' * 60}Asha'), '');
    expect(peerLabel(['${'.' * 60}Asha']), kUnnamedPeer);
  });

  test('fuzz: connect and invite links carry names no longer than a phone '
      'name and a group name', () {
    final rnd = Random(3903);
    for (var i = 0; i < 600; i++) {
      final n = _randomName(rnd, 1500);
      final f = _randomName(rnd, 1500);
      final connect = ConnectLink.tryParse(
        'settleup://sync?v=1&h=192.168.43.1:47321&d=dev-x'
        '&n=${Uri.encodeQueryComponent(n)}',
      )!;
      _expectPhoneName(connect.deviceName, n);
      final invite = InviteLink.tryParse(
        'settleup://join?v=1&g=g1&k=$_keyB64&c=INR'
        '&n=${Uri.encodeQueryComponent(n)}'
        '&f=${Uri.encodeQueryComponent(f)}',
      )!;
      _expectPhoneName(invite.fromName, f);
      expect(
        NameText.fits(invite.groupName, NameText.maxGroupLength),
        isTrue,
        reason: '${invite.groupName.characters.length} characters',
      );
      expect(invite.groupName, NameText.fit(n, NameText.maxGroupLength));
    }
  });

  test('a group name of 60 characters in an invite link is kept whole', () {
    final name = 'G' * NameText.maxGroupLength;
    final invite = InviteLink.tryParse(
      'settleup://join?v=1&g=g1&k=$_keyB64&c=INR&n=$name&f=Alex',
    )!;
    expect(invite.groupName, name);
    expect(
      InviteLink.tryParse(
        'settleup://join?v=1&g=g1&k=$_keyB64&c=INR&n=${name}xyz&f=Alex',
      )!.groupName,
      name,
    );
  });

  test('a Sync history record an earlier build stored with a long received '
      'name reads back cut to a phone name; others read back unchanged', () {
    SyncRecord record(String name) => SyncRecord(
      id: 'r1',
      peerName: name,
      transport: TransportKind.lan,
      startedAt: DateTime.utc(2026, 11, 1),
      endedAt: DateTime.utc(2026, 11, 1, 0, 1),
      sentOps: 0,
      receivedOps: 0,
      groupIds: const [],
      outcome: SyncOutcome.failed,
    );
    final hostile = List.filled(200, 'Pixel').join(' ');
    final long = syncRecordFromJson(
      syncRecordToJson(record(boundPeerName(hostile))),
    )!;
    expect(long.peerName, shownPeerName(hostile));
    _expectPhoneName(long.peerName, hostile);
    final blank = syncRecordFromJson(syncRecordToJson(record('​' * 200)))!;
    expect(blank.peerName, kUnnamedPeer);
    for (final name in ["Alex's Pixel", kUnnamedPeer, 'A' * 40]) {
      expect(
        syncRecordFromJson(syncRecordToJson(record(name)))!.peerName,
        name,
      );
    }
  });
}
