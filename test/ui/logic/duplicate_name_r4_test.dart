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
    // ZWJ and ZWNJ are kept by the Ledger, so they still tell names apart.
    expect(duplicateName('Ra\u200Dhul', existing), isNull);
    expect(duplicateName('\u200B', existing), isNull);
  });
}
