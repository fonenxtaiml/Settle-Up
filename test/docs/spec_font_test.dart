// SPEC names the font the app bundles (VISUAL-R1-15): the family and
// weights in DESIGN.md, lib/theme/app_theme.dart and assets/google_fonts/.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';

void main() {
  final spec = File('docs/SPEC.md').readAsStringSync();
  final fileStem = kFontFamily.replaceAll(' ', '');

  test('SPEC, DESIGN and the theme name the same family', () {
    expect(
      File('docs/design/DESIGN.md').readAsStringSync(),
      contains('fontFamily: $kFontFamily'),
    );
    expect(spec, contains(kFontFamily));
    expect(spec.toLowerCase(), isNot(contains('atkinson')));
  });

  test('every bundled TTF is the family SPEC names', () {
    final ttfs = Directory('assets/google_fonts')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.ttf'))
        .toList();
    expect(ttfs, hasLength(AppFonts.bundledWeights.length));
    for (final name in ttfs) {
      expect(name, startsWith('$fileStem-'));
    }
    expect(spec, contains('`$fileStem-Regular.ttf`'));
  });

  test('SPEC lists the bundled weights', () {
    final weights = AppFonts.bundledWeights
        .map((w) => w.value.toString())
        .join('/');
    expect(weights, '400/500/600/700');
    expect(spec, contains('$kFontFamily $weights'));
  });
}
