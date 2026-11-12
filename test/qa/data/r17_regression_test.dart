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

import '../../data/name_replay_perf_test.dart'
    show MarkCost, expectWithinMarkBudget, nameCost;
import '../../support/cpu_clock.dart' show cpuMicrosPer;
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

/// The CPU time one [NameText.display] of [name]s takes, in us
/// ([cpuMicrosPer]: the fastest of three windows of at least 40 ms of CPU
/// time after a warm-up), so neither the load the suite runs under, nor a
/// burst of it, nor the resolution of the clock decides (DATA-R21-01).
/// Windows of 300 displays, about 1 ms, read 0 us on the kernel's stepped
/// scheduler statistics, which made `5 x ordinary + 50` an absolute 50 us.
double displayMicros(String Function(int) name, int limit) =>
    cpuMicrosPer((i) => NameText.display(name(i), limit));

/// What the DATA-R15-01 reverification measures.
typedef R17Cost = ({
  double ordinary,
  double marks,
  double group,
  MarkCost open,
  int applyMs,
});

/// Measures what names of combining marks NFKC expands cost: one display
/// of such a name against an ordinary one, and 4,000 peer members created
/// with them against as many with ordinary names ([nameCost]: the CPU
/// time the names add, and each open the faster of two, measured beside
/// an ordinary one).
Future<R17Cost> measureR17() async {
  final ordinary = displayMicros((i) => 'Person ${'x' * 150}$i', 40);
  final marks = displayMicros(markName, 40);
  final group = displayMicros(
    (i) => 'x${'ཷ' * 238}${i % 10}',
    NameText.maxGroupLength,
  );
  final open = await nameCost(markName);
  final r = await logPhone(memberCreates(4000, markName), base: false);
  final sw = Stopwatch()..start();
  await r.phone.ledger.applyRemote(
    'group-1',
    memberCreates(1000, markName, from: 10000),
  );
  final applyMs = sw.elapsedMilliseconds;
  await r.phone.close();
  r.phone.dir.deleteSync(recursive: true);
  return (
    ordinary: ordinary,
    marks: marks,
    group: group,
    open: open,
    applyMs: applyMs,
  );
}

/// The charter: about 0.1 ms an op, so 4,000 ops open in < 400 ms on a
/// warm, quiet host whatever names they carry within the remote limits.
///
/// Held as the replay tests hold it ([expectWithinMarkBudget]): what the
/// names add in CPU time, which the load of the full suite (-j 2 on a
/// shared host) does not change, and the open on the wall clock against
/// an open of ordinary names measured beside it. One wall-clock open
/// against an absolute 400 ms failed whenever that load slowed ordinary
/// replay toward 400 ms (DATA-R21-01).
void expectR17(R17Cost r) {
  expectWithinMarkBudget(r.open);
  expect(r.marks, lessThan(5 * r.ordinary + 50));
  expect(r.group, lessThan(5 * r.ordinary + 50));
}

void main() {
  test('QA DATA-R15-01: names of combining marks that NFKC expands are still '
      'normalised whole, ~25x an ordinary name; 4,000 such peer members open '
      'in ~2.8 s', () async {
    final r = await measureR17();
    // ignore: avoid_print
    print(
      '[perf] display (CPU): ordinary ${r.ordinary.toStringAsFixed(0)} us, '
      'x+158 U+0344 ${r.marks.toStringAsFixed(0)} us, group x+238 U+0F77 '
      '${r.group.toStringAsFixed(0)} us; 4k distinct members open: '
      'ordinary ${r.open.ordinaryMs} ms, marks ${r.open.openMs} ms, the '
      'names ${r.open.cpuMs} ms of CPU; applyRemote 1k marks '
      '${r.applyMs} ms',
    );
    expectR17(r);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
