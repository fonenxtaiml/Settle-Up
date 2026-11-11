// QA DATA-R17: reverification of DATA-R15-01 on the integrated build. The
// fix rebuilds each entity once per batch and normalises a bounded head of
// a name that NFKC expands, but the head can only be cut where a character
// does not start with a combining mark. A name made of marks that NFKC
// expands (U+0344 is two marks, U+0F77 three) has no such place, so it is
// still normalised whole: 0.65-0.8 ms per name, ~25x an ordinary one.
//
// Tests named "QA <id>" with `skip:` are failing repros for open findings;
// they pass once the finding is fixed.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';

import 'qa_data_harness.dart';
import 'r15_regression_test.dart' show logPhone, peerD;

/// [n] member creates by peer D in `group-1`, each a distinct member.
List<Operation> memberCreates(
  int n,
  String Function(int) name, {
  int from = 0,
}) => [
  for (var i = from + 1; i <= from + n; i++)
    Operation(
      id: 'r17-mem-$i',
      groupId: 'group-1',
      deviceId: peerD,
      counter: i,
      hlc: Hlc(kQaBaseMs + i, 0, peerD),
      entityType: EntityType.member,
      entityId: 'r17-m$i',
      kind: OpKind.create,
      payload: {
        MemberFields.displayName: name(i),
        MemberFields.personId: 'r17-p$i',
        MemberFields.createdAt: kQaBaseMs,
      },
    ),
];

/// 'x' and 158 x U+0344 (NFKD: U+0308 U+0301), 160 units: within the
/// remote limit of a member name.
String markName(int i) => 'x${'̈́' * 158}${i % 10}';

double displayMicros(String Function(int) name, int limit) {
  for (var i = 0; i < 50; i++) {
    NameText.display(name(i), limit);
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < 300; i++) {
    NameText.display(name(i), limit);
  }
  return sw.elapsedMicroseconds / 300;
}

void main() {
  test(
    'QA DATA-R15-01: names of combining marks that NFKC expands are still '
    'normalised whole, ~25x an ordinary name; 4,000 such peer members open '
    'in ~2.8 s',
    () async {
      final ordinary = displayMicros((i) => 'Person ${'x' * 150}$i', 40);
      final marks = displayMicros(markName, 40);
      final group = displayMicros(
        (i) => 'x${'ཷ' * 238}${i % 10}',
        NameText.maxGroupLength,
      );
      final ok = await logPhone(
        memberCreates(4000, (i) => 'Person $i'),
        base: false,
      );
      await ok.phone.close();
      ok.phone.dir.deleteSync(recursive: true);
      final r = await logPhone(memberCreates(4000, markName), base: false);
      final sw = Stopwatch()..start();
      await r.phone.ledger.applyRemote(
        'group-1',
        memberCreates(1000, markName, from: 10000),
      );
      final applyMs = sw.elapsedMilliseconds;
      await r.phone.close();
      r.phone.dir.deleteSync(recursive: true);
      // ignore: avoid_print
      print(
        '[perf] display: ordinary ${ordinary.toStringAsFixed(0)} us, '
        'x+158 U+0344 ${marks.toStringAsFixed(0)} us, group x+238 U+0F77 '
        '${group.toStringAsFixed(0)} us; 4k distinct members open: '
        'ordinary ${ok.openMs} ms, marks ${r.openMs} ms; applyRemote 1k '
        'marks $applyMs ms',
      );
      // Charter: about 0.1 ms an op, so 4,000 ops open in < 400 ms on this
      // small log whatever names they carry within the remote limits.
      expect(r.openMs, lessThan(400));
      expect(marks, lessThan(5 * ordinary + 50));
      expect(group, lessThan(5 * ordinary + 50));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
