// QA SECURITY round 17: SECURITY-R15-02 reverification guard. A link's
// `n` and `f` values are cut to kMaxPeerNameUnits before they are
// normalised, so a hostile name of any shape parses in linear time and
// normalises at most a bounded number of code units.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_name.dart';

final String _key = 'A' * 43;

String _repeat(String s, int units) {
  final b = StringBuffer();
  while (b.length < units) {
    b.write(s);
  }
  return b.toString();
}

/// Shapes that cost unorm the most: mark runs of several classes,
/// conjuncts with joiners, joiners next to dropped marks, Hangul jamo,
/// a compatibility form that expands 18 times, tags.
final Map<String, String> _shapes = {
  'mark run': 'A${_repeat('̖́', 200000)}',
  'mark classes': 'A${_repeat('ְ̖́ͅ', 200000)}',
  'conjuncts': _repeat('क्‍', 200000),
  'joiner reorder': _repeat('क́‌़‍', 200000),
  'jamo': _repeat('각', 200000),
  'ligature': _repeat('ﷺ', 200000),
  'tags': '\u{1F3F4}${_repeat('\u{E0067}', 200000)}',
  'arabic marks': _repeat('لَّ‍؜', 200000),
};

void main() {
  for (final MapEntry(key: shape, value: name) in _shapes.entries) {
    test('a 200,000-unit "$shape" name in a link parses fast', () {
      final n = Uri.encodeQueryComponent(name);
      final sw = Stopwatch()..start();
      final invite = InviteLink.tryParse(
        'settleup://join?v=1&g=g1&k=$_key&c=INR&n=$n&f=$n',
      );
      final connect = ConnectLink.tryParse(
        'settleup://sync?v=1&h=192.168.1.2:4040&d=d1&n=$n',
      );
      sw.stop();
      expect(invite, isNotNull);
      expect(connect, isNotNull);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      final before = NameText.unormUnits;
      cleanPeerName(name);
      // 960 units in, at most a few passes of it through unorm.
      expect(NameText.unormUnits - before, lessThan(40 * kMaxPeerNameUnits));
    });
  }
}
