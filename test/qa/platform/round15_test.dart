// QA PLATFORM round 15 (final regression sweep): the startup path now runs
// every name through NameText (unorm_dart NFKC) before runApp: the phone
// model from device_info_plus in KvSettingsRepository.open, and every group
// and member name in the fold Ledger.open runs. A throw there would make
// realOverrides report a startup failure on every launch of that phone, so
// these probes check that no string of any code point class throws, that
// fit stays within its limit, and that opening the
// settings never fails for any phone model string.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/memory_op_store.dart';

/// Code points from every class NameText treats specially plus random ones.
const _interesting = <int>[
  0x00,
  0x09,
  0x0A,
  0x20,
  0x41,
  0x7F,
  0x85,
  0xA0,
  0xAD,
  0x034F,
  0x0300,
  0x0301,
  0x0627,
  0x0644,
  0x0915,
  0x094D,
  0x0937,
  0x115F,
  0x1160,
  0x200B,
  0x200C,
  0x200D,
  0x202E,
  0x2066,
  0x2026,
  0x2474,
  0x2800,
  0x3164,
  0x337F,
  0xD800,
  0xDBFF,
  0xDC00,
  0xDFFF,
  0xFDFA,
  0xFE0E,
  0xFE0F,
  0xFEFF,
  0xFFA0,
  0xFFFD,
  0xFFFE,
  0xFFFF,
  0x1F3F4,
  0x1F468,
  0x1F3FB,
  0x1F1EE,
  0x1F1F3,
  0x20E3,
  0xE0067,
  0xE0062,
  0xE007F,
  0x10FFFF,
  0x110BD,
  0x1D173,
];

String _randomName(Random rnd, int maxLen) {
  final n = rnd.nextInt(maxLen + 1);
  final b = StringBuffer();
  for (var i = 0; i < n; i++) {
    final pick = rnd.nextInt(4);
    if (pick == 0) {
      // A raw UTF-16 code unit, so lone surrogates of both kinds occur.
      b.writeCharCode(rnd.nextInt(0x10000));
    } else if (pick == 1) {
      b.writeCharCode(rnd.nextInt(0x110000));
    } else {
      final c = _interesting[rnd.nextInt(_interesting.length)];
      if (c >= 0xD800 && c <= 0xDFFF) {
        b.write(String.fromCharCode(c));
      } else {
        b.writeCharCode(c);
      }
    }
  }
  return b.toString();
}

void main() {
  group('NameText never throws on the startup path', () {
    test('normalize, fit, display, isValid and key over random strings', () {
      final rnd = Random(15);
      for (var i = 0; i < 4000; i++) {
        final raw = _randomName(rnd, i.isEven ? 12 : 300);
        for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
          final String fitted;
          try {
            NameText.normalize(raw);
            fitted = NameText.fit(raw, limit);
            NameText.display(raw, limit);
            NameText.isValid(raw, limit);
            NameText.key(raw, limit);
          } on Object catch (e) {
            fail('threw $e for ${raw.codeUnits}');
          }
          expect(
            NameText.fits(fitted, limit),
            isTrue,
            reason: 'fit over its limit for ${raw.codeUnits}',
          );
        }
      }
    });

    // Found by this sweep: normalize keeps a ZWJ or ZWNJ when the next
    // raw code point is a letter of a joining script, but that next code
    // point may itself be an invisible one it then drops (U+061C ARABIC
    // LETTER MARK, U+0600-0605, U+17B4/5, U+180B-180F, U+110BD, ...). The
    // first pass keeps the joiner with nothing after it to join; the
    // second pass drops it. So what Ledger and Settings store (fit once)
    // is not what the fold shows (display = fit again), against the
    // documented "Idempotent: fit(fit(x)) == fit(x)" (SPEC 5.16).
    test(
      'normalize and fit are idempotent when a joiner precedes a dropped '
      'invisible in a joining script',
      () {
        const cases = <String>[
          '\u0628\u200D\u061C', // beh, ZWJ, Arabic letter mark
          'Ali \u0628\u200D\u061C',
          '\u0628\u200D\u061C x',
          '\u0915\u200C\u0600 a', // ka, ZWNJ, Arabic number sign
          '\u0915\u094D\u200D\u17B4', // ka virama, ZWJ, Khmer inherent
          '\u0915\u200D\u180B', // ka, ZWJ, Mongolian FVS1
        ];
        for (final raw in cases) {
          final hex = raw.runes.map((r) => r.toRadixString(16)).join(' ');
          final n = NameText.normalize(raw);
          expect(NameText.normalize(n), n, reason: 'normalize: $hex');
          final f = NameText.fit(raw);
          expect(NameText.fit(f), f, reason: 'fit: $hex');
          // What the fold shows is what was stored.
          expect(NameText.display(f), f, reason: 'display: $hex');
        }
      },
      skip:
          'QA PLATFORM-R15-01: NameText.normalize is not idempotent after '
          'a joiner followed by a dropped invisible',
    );

    test('a very long phone model is cut, not refused', () {
      final long = 'Pixel ' * 2000;
      expect(() => NameText.fit(long), returnsNormally);
      expect(NameText.fits(NameText.fit(long), NameText.maxLength), isTrue);
    });
  });

  group('KvSettingsRepository.open accepts any phone model string', () {
    test('first launch never throws and always stores a usable name', () async {
      final rnd = Random(1515);
      final models = <String>[
        '',
        ' ',
        'ㅤ',
        '\uD800',
        '\uDC00x',
        '-',
        '😎',
        'Ｐｉｘｅｌ ８',
        'SM-S928B\u0000',
        'Pixel ' * 500,
        for (var i = 0; i < 300; i++) _randomName(rnd, 80),
      ];
      for (final model in models) {
        final store = MemoryOpStore();
        final KvSettingsRepository settings;
        try {
          settings = await KvSettingsRepository.open(
            store,
            defaultDeviceName: model,
            localeName: 'en_IN',
          );
        } on Object catch (e) {
          fail('open threw $e for model ${model.codeUnits}');
        }
        final name = settings.device.deviceName;
        expect(name, isNotEmpty, reason: 'model ${model.codeUnits}');
        expect(
          NameText.isValid(name),
          isTrue,
          reason: 'stored "$name" for model ${model.codeUnits}',
        );
        // A second launch reads it back unchanged.
        final again = await KvSettingsRepository.open(
          store,
          defaultDeviceName: 'other',
          localeName: 'en_IN',
        );
        expect(again.device.deviceName, name);
        expect(again.device.deviceId, settings.device.deviceId);
      }
    });
  });
}
