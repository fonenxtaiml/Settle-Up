// QA DATA-R18: open findings from the reverification of DATA-R15-01.
//
// Tests named "QA <id>" with `skip:` are failing repros for open findings;
// they pass once the finding is fixed.
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../../data/name_replay_perf_test.dart' show creates, openMs;
import 'r15_regression_test.dart' show logPhone;
import 'r17_regression_test.dart' show memberCreates;

/// A member name of 80 astral code points (160 units, the remote limit of
/// a member name): the [i]th run of 80 of the 1,048,576 astral code points.
String astralName(int i) {
  final b = StringBuffer();
  for (var k = 0; k < 80; k++) {
    final r = 0x10000 + (i * 80 + k) % 0x100000;
    // Noncharacters (U+xFFFE, U+xFFFF) are code points like any other here.
    b.writeCharCode(r);
  }
  return b.toString();
}

void main() {
  test(
    'QA DATA-R18-01: peer member names holding distinct astral code points '
    'grow the normaliser caches without bound (~130 MiB) and open 13k ops '
    'in ~4 s, on every launch',
    () async {
      const n = 0x100000 ~/ 80; // 13,107 ops cover every astral code point
      // The same number of ordinary members first, so the growth measured
      // below is the names, not the log or the ledger.
      final control = await logPhone(
        memberCreates(n, (i) => 'Person $i'),
        base: false,
      );
      await control.phone.close();
      control.phone.dir.deleteSync(recursive: true);
      final ordinaryRss = ProcessInfo.currentRss;
      final ordinaryAgain = await logPhone(
        memberCreates(n, (i) => 'Person $i'),
        base: false,
      );
      final ordinaryGrowth = ProcessInfo.currentRss - ordinaryRss;
      await ordinaryAgain.phone.close();
      ordinaryAgain.phone.dir.deleteSync(recursive: true);

      final before = ProcessInfo.currentRss;
      final r = await logPhone(memberCreates(n, astralName), base: false);
      final growth = ProcessInfo.currentRss - before;
      final members = r.phone.group('group-1').members;
      final accepted = members.keys.where((m) => m.startsWith('r17-m')).length;
      await r.phone.close();
      r.phone.dir.deleteSync(recursive: true);
      // ignore: avoid_print
      print(
        '[mem] $n peer members: ordinary names grow RSS by '
        '${ordinaryGrowth >> 20} MiB, astral names by ${growth >> 20} MiB '
        '(open: ordinary ${ordinaryAgain.openMs} ms, astral ${r.openMs} ms; '
        '$accepted members shown)',
      );
      expect(accepted, n); // the ops are within the remote limits
      // The normaliser's per-code-point tables should be bounded, like
      // NameText's marks cache (4,096 entries).
      expect(growth - ordinaryGrowth, lessThan(32 << 20));
      // The charter: 20k ops open in < 2 s on the host whatever names they
      // carry within the remote limits; these are 13k.
      expect(r.openMs, lessThan(2000));
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip:
        'QA DATA-R18-01: peer names holding distinct astral code points '
        'grow the normaliser caches without bound and slow every open',
  );

  test(
    'QA DATA-R18-02: the DATA-R15-01 perf tests fail under the load of the '
    'full suite (-j 2): 4k members with marks after spaces or split by soft '
    'hyphens add 320-370 ms against a bound of 300',
    () async {
      // Four busy isolates stand in for the other test process the full
      // suite runs beside this one with -j 2, and the other work on the
      // shared 4-CPU host.
      final stops = <Isolate>[
        for (var k = 0; k < 4; k++)
          await Isolate.spawn((_) {
            var x = 0;
            while (true) {
              x = (x * 31 + 7) & 0xFFFFFF;
            }
          }, null),
      ];
      String Function(int) of(String piece) => (i) {
        final b = StringBuffer('$i');
        while (b.length + piece.length <= 160) {
          b.write(piece);
        }
        return b.toString();
      };
      final rows = <String>[];
      var worst = 0;
      try {
        for (final piece in ['ཷ ', 'ཷ­']) {
          var ordinary = 1 << 30, ms = 1 << 30;
          for (var k = 0; k < 2; k++) {
            ordinary = min(
              ordinary,
              await openMs(creates(4000, (i) => 'Person $i'), base: false),
            );
            ms = min(ms, await openMs(creates(4000, of(piece)), base: false));
          }
          rows.add(
            '${piece.codeUnits.last.toRadixString(16)}: '
            '${ms - ordinary} ms',
          );
          worst = max(worst, ms - ordinary);
        }
      } finally {
        for (final i in stops) {
          i.kill(priority: Isolate.immediate);
        }
      }
      // ignore: avoid_print
      print('[perf] under load, added by 4k mark-heavy members: $rows');
      // The bound name_replay_perf_test.dart asserts; the suite must stay
      // green on the shared host it runs on.
      expect(worst, lessThan(300));
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip:
        'QA DATA-R18-02: the DATA-R15-01 perf tests fail under the load of '
        'the full suite',
  );
}
