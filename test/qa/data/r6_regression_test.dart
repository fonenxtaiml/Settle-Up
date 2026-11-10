// QA DATA-R6: reverification of the round-5 data fixes (DATA-R5-01 advert
// names cut on character boundaries, DATA-R5-02 a first character longer
// than the limit cut by code points instead of sent empty, DATA-R5-03 a
// CSV name that starts with dots and spaces), the cases next to them, and
// round-6 findings (DATA-R6-NN, skipped until fixed).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/name_cut.dart';
import 'package:settle_up/sync/peer_name.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/transport/ble/ble_chunker.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/screens/csv_share.dart';

import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';
import 'qa_data_harness.dart';

bool wellFormed(String s) => utf8.decode(utf8.encode(s)) == s;

/// True when [cut] is [whole] cut on a grapheme cluster boundary.
bool clusterPrefix(String whole, String cut) =>
    whole.characters.startsWith(cut.characters);

/// Tokens as the advert carries them: 4 base32-ish characters each.
List<String> tokens(int n) => [
  for (var i = 0; i < n; i++)
    String.fromCharCodes([
      65 + (i ~/ 676) % 26,
      65 + (i ~/ 26) % 26,
      65 + i % 26,
      50 + i % 8,
    ]),
];

final pieces = [
  'a',
  ' ',
  'Z',
  '\u{1F1EE}\u{1F1F3}',
  'क्ष',
  'क्षि',
  'e\u0301',
  'o${'\u0301' * 30}',
  '\u{20000}',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}',
  '\u{1F44D}\u{1F3FD}',
  'ñ',
];

String randomName(Random rnd, int maxClusters) {
  final sb = StringBuffer();
  final n = 1 + rnd.nextInt(maxClusters);
  for (var k = 0; k < n; k++) {
    sb.write(pieces[rnd.nextInt(pieces.length)]);
  }
  // Settings trims; a name never starts or ends with a space.
  final t = sb.toString().trim();
  return t.isEmpty ? 'a' : t;
}

void main() {
  group('DATA-R5-01 reverify (advert names on character boundaries)', () {
    const advertId = 'a1b2c3d4';
    AdvertiseInfo info(String name, {int tokenCount = 1, int? tag}) =>
        AdvertiseInfo(
          deviceId: 'eeeeeeee-0000-7000-8000-0000000000e9',
          deviceName: name,
          groupTokens: tokens(tokenCount),
          advertId: advertId,
          tokenWindow: tag,
        );

    test('the repro: flags and conjuncts are cut between characters on '
        'every transport', () {
      for (final name in ['a${'\u{1F1EE}\u{1F1F3}' * 26}', 'क्ष' * 40]) {
        final got = {
          'mdns': MdnsAdvert.serviceNameFor(name),
          'ble': BleInfo.tryParse(BleInfo.of(info(name)).encode())!.deviceName,
          'nearby': NearbyEndpointName.tryParse(
            NearbyEndpointName.of(info(name)).encode(),
          )!.deviceName,
        };
        got.forEach((kind, n) {
          expect(wellFormed(n), isTrue, reason: kind);
          expect(clusterPrefix(name, n), isTrue, reason: '$kind: $n');
          expect(n, isNotEmpty, reason: kind);
        });
      }
    });

    test('fuzz: every advert keeps the longest whole-character prefix that '
        'fits, within its limits, with few and with full token lists', () {
      final rnd = Random(61);
      for (var i = 0; i < 1500; i++) {
        final name = randomName(rnd, 40);
        for (final tc in [1, 24, 200]) {
          final ad = info(name, tokenCount: tc, tag: rnd.nextInt(4096));

          // mDNS: 40 units and one DNS label (63 bytes).
          final m = MdnsAdvert.serviceNameFor(name);
          expect(m.length, lessThanOrEqualTo(kLanServiceNameMax));
          expect(utf8.encode(m).length, lessThanOrEqualTo(63));
          expect(wellFormed(m), isTrue);

          // BLE: 40 code points, whole INFO <= 512 bytes.
          final bleBytes = BleInfo.of(ad).encode();
          expect(bleBytes.length, lessThanOrEqualTo(kBleMaxAttPayload));
          final b = BleInfo.tryParse(bleBytes)!.deviceName;
          expect(b.runes.length, lessThanOrEqualTo(BleInfo.maxNameRunes));
          expect(wellFormed(b), isTrue);

          // Nearby: 24 code points, the whole name <= 131 bytes.
          final enc = NearbyEndpointName.of(ad).encode();
          expect(
            utf8.encode(enc).length,
            lessThanOrEqualTo(NearbyEndpointName.maxBytes),
          );
          final nb = NearbyEndpointName.tryParse(enc)!.deviceName;
          expect(
            nb.runes.length,
            lessThanOrEqualTo(NearbyEndpointName.maxNameRunes),
          );
          expect(wellFormed(nb), isTrue);

          for (final (kind, got) in [('mdns', m), ('ble', b), ('nearby', nb)]) {
            expect(got, isNotEmpty, reason: '$kind $name');
            final first = name.characters.first;
            if (got.characters.length == 1 && got.length < first.length) {
              // The DATA-R5-02 fallback: a code-point cut of the first
              // character, never empty.
              expect(first.startsWith(got), isTrue, reason: kind);
              continue;
            }
            expect(clusterPrefix(name, got), isTrue, reason: '$kind $got');
          }
          // Maximal for the unit and byte limits (mDNS).
          if (m != name) {
            final next = name.characters.skip(m.characters.length).first;
            final more = '$m$next';
            expect(
              more.length > kLanServiceNameMax || utf8.encode(more).length > 63,
              isTrue,
              reason: name,
            );
          }
        }
      }
    });

    test('a 40-character Devanagari name fits a DNS label without being '
        'cut inside a character', () {
      final name = 'क्षि' * 10; // 40 units, 120 bytes
      final m = MdnsAdvert.serviceNameFor(name);
      expect(utf8.encode(m).length, lessThanOrEqualTo(63));
      expect(clusterPrefix(name, m), isTrue);
      expect(m, 'क्षि' * 5); // 60 bytes; a sixth would be 72
    });

    test('a blank or space-only name still advertises "Settle Up" over '
        'mDNS', () {
      expect(MdnsAdvert.serviceNameFor('   '), 'Settle Up');
      expect(MdnsAdvert.serviceNameFor(''), 'Settle Up');
    });

    test('cutName never splits a code point and is empty only for an '
        'empty name', () {
      final rnd = Random(62);
      for (var i = 0; i < 2000; i++) {
        final name = randomName(rnd, 20);
        final limit = 1 + rnd.nextInt(60);
        final cut = cutName(name, (s) => utf8.encode(s).length <= limit);
        expect(wellFormed(cut), isTrue);
        expect(utf8.encode(cut).length, lessThanOrEqualTo(limit));
        expect(name.startsWith(cut), isTrue);
        // The first code point is at most 4 bytes.
        if (limit >= 4) expect(cut, isNotEmpty, reason: '$limit $name');
      }
      expect(cutName('', (s) => s.length <= 3), '');
      expect(cutName('abc', (s) => s.isEmpty), '');
    });
  });

  group('DATA-R5-02 reverify (first character longer than the limit)', () {
    Future<String> helloOf(String deviceName) async {
      final hs = await Handshake.start(
        initiator: true,
        groupKeys: {'g': Uint8List.fromList(List.generate(32, (i) => i))},
        deviceId: 'eeeeeeee-0000-7000-8000-0000000000e9',
        deviceName: deviceName,
        maxFrame: 16384,
        transport: TransportKind.lan,
        random: Random(1),
      );
      final json = jsonDecode(
        utf8.decode(utf8.encode(jsonEncode(hs.hello.toJson()))),
      ) as Map<String, Object?>;
      final read =
          SyncMessage.fromJson(MessageType.hello, json) as HelloMessage;
      return read.deviceName;
    }

    test('the repro and its neighbours are sent as a non-empty, '
        'well-formed name', () async {
      final cases = <String, String>{
        'a${'\u0301' * 100}': 'a${'\u0301' * 99}',
        'a${'\u0301' * 300}': 'a${'\u0301' * 99}',
        // The over-long character second: the first one alone is kept.
        'b${'a${'\u0301' * 100}'}': 'b',
        // A long astral cluster: never a lone surrogate.
        '\u{20000}${'\u0301' * 120}': '\u{20000}${'\u0301' * 98}',
        'a${'\u0301' * 99}': 'a${'\u0301' * 99}',
      };
      for (final e in cases.entries) {
        final sent = await helloOf(e.key);
        expect(sent, e.value, reason: e.key.length.toString());
        expect(wellFormed(sent), isTrue);
        expect(cleanPeerName(sent), isNotEmpty);
      }
    });

    test('settings accepts the repro name and every advert sends its base '
        'letter', () async {
      final name = 'a${'\u0301' * 100}';
      expect(name.characters.length, 1);
      expect(
        name.characters.length,
        lessThanOrEqualTo(KvSettingsRepository.maxNameLength),
      );
      final ad = AdvertiseInfo(
        deviceId: 'eeeeeeee-0000-7000-8000-0000000000e9',
        deviceName: name,
        groupTokens: tokens(24),
        advertId: 'a1b2c3d4',
        tokenWindow: 4095,
      );
      final m = MdnsAdvert.serviceNameFor(name);
      final b = BleInfo.tryParse(BleInfo.of(ad).encode())!.deviceName;
      final n = NearbyEndpointName.tryParse(NearbyEndpointName.of(ad).encode())!
          .deviceName;
      for (final got in [m, b, n]) {
        expect(got, startsWith('a'));
        expect(name.startsWith(got), isTrue);
      }
      expect(m, 'a${'\u0301' * 31}'); // 63 bytes
      expect(b.runes.length, 40);
    });

    group('session name fallback', () {
      late TestPhone alex, priya;
      setUp(() async {
        alex = await TestPhone.create('a', deviceName: "Alex's Pixel");
        priya = await TestPhone.create(
          'b',
          deviceName: "Priya's Pixel",
          name: 'Priya',
        );
      });
      tearDown(() async {
        await alex.close();
        await priya.close();
      });

      Future<String> nameSeenByAlex(String priyaName, String hint) async {
        final s = await alex.seedGroup(expenses: 1);
        await priya.join(alex, s.g);
        await priya.settings.setDeviceName(priyaName);
        final (ci, cr) = await channelPair();
        final si = SyncSession(
          channel: ci,
          store: alex.store,
          role: SessionRole.initiator,
          timings: fastTimings,
          peerNameHint: hint,
        );
        final sr = SyncSession(
          channel: cr,
          store: priya.store,
          role: SessionRole.responder,
          timings: fastTimings,
        );
        final results = await Future.wait([si.run(), sr.run()]);
        expect(results[0].outcome, SyncOutcome.completed);
        return results[0].peerName;
      }

      test('a visible HELLO name wins over the hint', () async {
        expect(await nameSeenByAlex('Priya P', 'Pixel'), 'Priya P');
      });

      test(
        'the repro name reaches the peer as its base letter and marks',
        () async {
          final got = await nameSeenByAlex('a${'\u0301' * 100}', 'hint');
          // Settings stores the name normalised (NFC: 'á' and 99 marks, 100
          // units), which the HELLO carries whole.
          expect(got, '\u00E1${'\u0301' * 99}');
        },
      );

      test('DATA-R6-01: a phone name that shows nothing is shown as a blank '
          'name on the other phone', () async {
        // Settings only trims, so each of these is a 1-character phone
        // name. The phone advertises the same name, so the scanner's hint
        // is the same blank text (the advert carries the device name).
        for (final blank in ['\u200B', '\u3164', '\u2800', '\u115F']) {
          final hint = cleanPeerName(MdnsAdvert.serviceNameFor(blank));
          final got = await nameSeenByAlex(blank, hint);
          // Expected: a name with something to show, such as a fallback
          // "Phone" (the fake engine uses 'Phone' for an empty name).
          // Actual: '' for the zero-width space, and an invisible filler
          // for U+3164 / U+2800 / U+115F (the session falls back to the
          // hint only when the cleaned HELLO name is empty, not blank),
          // so the session screen, Sync screen and history read
          // "Synced with " with no name.
          expect(
            TextRules.isBlank(got),
            isFalse,
            reason: 'U+${blank.runes.first.toRadixString(16)} -> "$got"',
          );
        }
      }, skip: 'DATA-R6-01');
    });
  });

  group('DATA-R5-03 reverify (leading dots and spaces in a CSV name)', () {
    test('the repro and its neighbours never start with a dot', () {
      final cases = <String, String>{
        '. .Goa trip': 'Goa trip',
        '.. . Goa trip': 'Goa trip',
        '🎉. .party': 'party',
        '.Goa trip': 'Goa trip',
        ' . . . . x': 'x',
        '...': kCsvFallbackName,
        '. . .': kCsvFallbackName,
        '🎉 . 🎉 . trip': 'trip',
        '\u200B.Goa': 'Goa',
        '\u00A0.Goa': 'Goa',
        '\t.\n.Goa': 'Goa',
        'Goa. .trip': 'Goa. .trip',
        'Goa trip.': 'Goa trip.',
      };
      cases.forEach((name, base) {
        expect(csvFileName(name), '$base.csv', reason: name);
      });
    });

    test('fuzz: no CSV name is hidden, blank-led, empty or over 80 units', () {
      final rnd = Random(63);
      final bits = [
        '.',
        ' ',
        '. ',
        '🎉',
        '\u200B',
        '\u00A0',
        'a',
        'क्ष',
        'e\u0301',
        '\u0301',
        '-',
        '_',
        '(',
        'o${'\u0301' * 90}',
      ];
      for (var i = 0; i < 4000; i++) {
        final sb = StringBuffer();
        final n = 1 + rnd.nextInt(25);
        for (var k = 0; k < n; k++) {
          sb.write(bits[rnd.nextInt(bits.length)]);
        }
        final name = sb.toString();
        final file = csvFileName(name);
        final base = file.substring(0, file.length - 4);
        expect(file.endsWith('.csv'), isTrue);
        expect(base, isNotEmpty, reason: name);
        expect(base.startsWith('.'), isFalse, reason: '$name -> $file');
        expect(base.startsWith(' '), isFalse, reason: name);
        expect(base.endsWith(' '), isFalse, reason: name);
        expect(base.length, lessThanOrEqualTo(80), reason: name);
        expect(wellFormed(base), isTrue, reason: name);
      }
    });
  });
  group('neighbours: names Settings keeps', () {
    test('DATA-R6-02: a profile name that shows nothing is accepted, then '
        'no group can be created', () async {
      for (final blank in ['​', 'ㅤ', '⠀', '\u{E0020}']) {
        resetKeystore();
        final phone = FilePhone(qaTempDir());
        await phone.launch();
        // Onboarding only trims ("Your name" -> Start), so each of these
        // is saved as the profile name, and Settings shows a blank name.
        Object? onboarding;
        try {
          await phone.settings.completeOnboarding(
            displayName: blank,
            homeCurrency: 'INR',
          );
        } on Object catch (e) {
          onboarding = e;
        }
        Object? create;
        if (onboarding == null) {
          try {
            await phone.ledger.createGroup(
              const NewGroup(
                name: 'Goa trip',
                type: GroupType.trip,
                currency: 'INR',
                newMemberNames: ['Sam'],
              ),
            );
          } on Object catch (e) {
            create = e;
          }
        }
        await phone.close();
        // Expected: the name is refused where it is typed (as a blank
        // member name is), or the phone can still create a group.
        // Actual: onboarding saves it, then every New group / Add friend
        // fails with "Your name is empty" until the user finds Settings >
        // Edit name. The same holds for Edit name later: the profile is
        // saved blank, then renaming my member in each group is refused.
        expect(
          onboarding != null || create == null,
          isTrue,
          reason: 'U+${blank.runes.first.toRadixString(16)}: $create',
        );
      }
    });
  });
}
