// duplicateName compares names as the Ledger stores them (UIFLOW-R4-01).
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/ui/screens/common.dart';

void main() {
  test('invisible marks never make a stored duplicate look new', () {
    const existing = ['Arjun', 'Priya', 'Rahul'];
    for (final mark in [
      '\u200B',
      '\u200E',
      '\u200F',
      '\u2060',
      '\uFEFF',
      '\u202A',
      '\u2066',
      '\u0007',
    ]) {
      for (final name in ['Rahul$mark', '${mark}Rahul', 'Ra${mark}hul']) {
        expect(
          duplicateName(name, existing),
          'Rahul',
          reason: name.runes.map((r) => r.toRadixString(16)).join(' '),
        );
        // It is the name the Ledger would save.
        expect(TextClean.clean(name), 'Rahul');
      }
    }
    // An existing name with a mark (from an older phone) is matched and
    // shown without it.
    expect(duplicateName('rahul', ['\u200ERahul']), 'Rahul');
    // ZWJ and ZWNJ are kept by the Ledger, but they draw nothing between
    // letters, so they never tell two names apart (UIFLOW-R5-01).
    expect(duplicateName('Ra\u200Dhul', existing), 'Rahul');
    expect(duplicateName('\u200B', existing), isNull);
  });

  test('blank marks the Ledger keeps inside a name do not make it a new '
      'name (UIFLOW-R5-01)', () {
    const existing = ['Arjun', 'Priya', 'Rahul'];
    for (final mark in [
      0x00AD, 0x034F, 0x115F, 0x17B4, 0x180E, 0x200C, 0x200D, 0x2060, //
      0x2061, 0x2063, 0x2064, 0x3164, 0xFE00, 0xFE0F, 0xFFA0, 0xE0001,
    ]) {
      final m = String.fromCharCode(mark);
      // A Hangul filler draws as wide as a space: "Ra" + U+3164 + "hul"
      // looks like "Ra hul" (UIFLOW-R6-01).
      final spaceWide = const [0x115F, 0x3164, 0xFFA0].contains(mark);
      for (final name in [
        'Rahul$m',
        '${m}Rahul',
        if (!spaceWide) 'Ra${m}hul',
        'rahul $m',
      ]) {
        expect(
          duplicateName(name, existing),
          'Rahul',
          reason: 'U+${mark.toRadixString(16)} in $name',
        );
      }
      // An existing name stored with the mark is matched as well, and
      // named as it is shown.
      expect(duplicateName('Rahul', ['Rahul$m']), 'Rahul');
    }
    // A name made only of blank marks is not a duplicate of anything (the
    // Ledger refuses it as blank), and different names stay different.
    expect(duplicateName('\u00AD\u200D', existing), isNull);
    expect(duplicateName('Rahul\u00ADK', existing), isNull);
    // Emoji keep their joiners in what is stored.
    expect(duplicateName('\u{1F469}\u200D\u{1F4BB}', existing), isNull);
  });
}
