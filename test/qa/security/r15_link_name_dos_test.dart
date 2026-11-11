// QA SECURITY round 15: full regression sweep.
//
// SECURITY-R15-02: since names from links are normalised with NFKC
// (cleanPeerName is NameText.normalize, UIFLOW-R6-01), InviteLink.tryParse
// and ConnectLink.tryParse run unorm_dart over the raw, unbounded `n` and
// `f` query values before any length limit. unorm's normalisation is
// quadratic in the length of a run of combining marks, so a crafted
// settleup:// link (a "Zalgo" group or phone name of tens of thousands of
// marks, a few hundred KB of URL) freezes the UI isolate for seconds to
// minutes when it is opened from a chat or web page: the join screen, the
// router and acceptInvite each parse it. Before the change TextClean.clean
// read these names in linear time. HELLO names, adverts and ops are not
// affected: they are length-checked before they are normalised.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/pairing/links.dart';

const int _marks = 24000;

/// A name of one letter and [_marks] combining marks of two classes.
final String _zalgo =
    'A${List.generate(_marks, (i) => i.isEven ? '́' : '̖').join()}';

final String _key = 'A' * 43; // 32 zero-ish bytes, base64url without '='

/// A linear parse of a URL this size takes a few ms on a test runner; a
/// phone is several times slower.
const Duration _budget = Duration(seconds: 1);

Duration _time(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  return sw.elapsed;
}

void main() {
  group('SECURITY-R15-02: a crafted link name stalls link parsing', () {
    test(
      'InviteLink.tryParse reads a $_marks-mark group name in linear time',
      () {
        final link =
            'settleup://join?v=1&g=g1&k=$_key&c=INR'
            '&n=${Uri.encodeQueryComponent(_zalgo)}&f=Asha';
        late InviteLink? parsed;
        final took = _time(() => parsed = InviteLink.tryParse(link));
        expect(parsed, isNotNull);
        expect(
          took,
          lessThan(_budget),
          reason: 'parse took ${took.inMilliseconds} ms',
        );
      },
      skip:
          'QA SECURITY-R15-02: a crafted link name makes invite and '
          'connect link parsing quadratic',
    );

    test(
      'InviteLink.tryParse reads a $_marks-mark inviter name in linear time',
      () {
        final link =
            'settleup://join?v=1&g=g1&k=$_key&c=INR&n=Trip'
            '&f=${Uri.encodeQueryComponent(_zalgo)}';
        late InviteLink? parsed;
        final took = _time(() => parsed = InviteLink.tryParse(link));
        expect(parsed, isNotNull);
        expect(
          took,
          lessThan(_budget),
          reason: 'parse took ${took.inMilliseconds} ms',
        );
      },
      skip:
          'QA SECURITY-R15-02: a crafted link name makes invite and '
          'connect link parsing quadratic',
    );

    test(
      'ConnectLink.tryParse reads a $_marks-mark phone name in linear time',
      () {
        final link =
            'settleup://sync?v=1&h=192.168.43.1:52741&d=dev1'
            '&n=${Uri.encodeQueryComponent(_zalgo)}';
        late ConnectLink? parsed;
        final took = _time(() => parsed = ConnectLink.tryParse(link));
        expect(parsed, isNotNull);
        expect(
          took,
          lessThan(_budget),
          reason: 'parse took ${took.inMilliseconds} ms',
        );
      },
      skip:
          'QA SECURITY-R15-02: a crafted link name makes invite and '
          'connect link parsing quadratic',
    );

    test('control: a long name without combining marks parses fast', () {
      final link =
          'settleup://join?v=1&g=g1&k=$_key&c=INR'
          '&n=${Uri.encodeQueryComponent('Trip ' * 5000)}&f=Asha';
      final took = _time(() => InviteLink.tryParse(link));
      expect(took, lessThan(_budget));
    });
  });
}
