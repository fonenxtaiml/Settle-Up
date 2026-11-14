// OpFactory stamping against a stored op log (no Ledger): a local write
// on an entity is stamped after the entity's newest op whoever wrote it
// and however far ahead (MONEY-R39-01), and own stamps stay unique after
// the clock was set back past the lead.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/op_factory.dart';

const int _day = 24 * 60 * 60 * 1000;
const int _base = 1762700000000;
const DeviceId _me = 'dev-m';
const List<DeviceId> _peers = ['dev-a', 'dev-z'];
const GroupId _g = 'g';

/// A stored op log the factory reads, like the Ledger's.
final class _Log {
  final List<Operation> ops = [];
  int now = _base;
  late final OpFactory factory = OpFactory(
    deviceId: _me,
    clock: HlcClock(deviceId: _me, nowMillis: () => now),
    ids: SequentialIdGenerator(),
    nowMillis: () => now,
    lastHlcOf: (g, type, id) {
      Hlc? top;
      for (final op in ops) {
        if (op.entityId == id && (top == null || op.hlc > top)) top = op.hlc;
      }
      return top;
    },
    newestStamp: (max) {
      Hlc? top;
      for (final op in ops) {
        if (max != null && op.hlc.millis > max) continue;
        if (top == null || op.hlc > top) top = op.hlc;
      }
      return top;
    },
  );

  Operation local(String entity) {
    final b = factory.batch();
    final op = b.update(_g, EntityType.expense, entity, {'description': 'x'});
    ops.add(op);
    b.commit();
    return op;
  }

  Operation peer(String entity, Hlc hlc) {
    final op = Operation(
      id: 'p${ops.length}',
      groupId: _g,
      deviceId: hlc.deviceId,
      counter: ops.length + 1,
      hlc: hlc,
      entityType: EntityType.expense,
      entityId: entity,
      kind: OpKind.update,
      payload: const {'description': 'y'},
    );
    ops.add(op);
    return op;
  }

  Hlc newestOf(String entity) => ops
      .where((o) => o.entityId == entity)
      .map((o) => o.hlc)
      .reduce((a, b) => a > b ? a : b);
}

void main() {
  test('MONEY-R39-01: a peer stamp more than 7 days ahead (adopted from '
      'this phone) is still followed', () {
    final log = _Log();
    log.now = _base + 15 * _day ~/ 2;
    final mine = log.local('e');
    log.peer('e', Hlc(mine.hlc.millis, mine.hlc.counter + 1, 'dev-a'));
    log.now = _base;
    final floor = log.newestOf('e');
    expect(floor.millis - log.now, greaterThan(HlcClock.maxAdoptDriftMs));
    final edit = log.local('e');
    expect(edit.hlc > floor, isTrue);
    // A new entity is stamped from the wall clock again.
    final other = log.local('f');
    expect(other.hlc.millis, lessThanOrEqualTo(log.now + OpFactory.maxLeadMs));
  });

  test('following a floor past the set-back clock never reuses an own '
      'stamp', () {
    final log = _Log();
    // This phone, 6 days ahead, adopts a peer stamp on 'x' and writes
    // (M, 1); the peer's (M, 0) is the newest op of 'y'.
    log.now = _base + 6 * _day;
    final m = log.now + 10;
    log.peer('x', Hlc(m, 0, 'dev-a'));
    final own = log.local('x');
    expect(own.hlc, Hlc(m, 1, _me));
    log.peer('y', Hlc(m, 0, 'dev-z'));
    // The date is corrected: the clock is set back past the lead, then an
    // edit of 'y' adopts (M, 0) and would tick to (M, 1) again.
    log.now = _base;
    log.local('z');
    final edit = log.local('y');
    expect(edit.hlc > Hlc(m, 0, 'dev-z'), isTrue);
    expect(edit.hlc, isNot(own.hlc));
    expect(edit.hlc > own.hlc, isTrue);
  });

  // Property: whatever the wall clock does and whatever peers stamp (often
  // in the same millisecond as a stamp already held), every local write
  // is stamped after its entity's newest op and no two own stamps are
  // equal.
  for (var seed = 1; seed <= 40; seed++) {
    test('seeded stamps $seed', () {
      final r = Random(seed);
      final log = _Log();
      const entities = ['a', 'b', 'c', 'd'];
      final jumps = [0, 0, 1, -1, 3, 6, 8, 12, 30];
      var real = _base;
      for (var step = 0; step < 300; step++) {
        real += r.nextInt(3) == 0 ? 0 : r.nextInt(2000);
        if (r.nextInt(8) == 0) {
          log.now = real + jumps[r.nextInt(jumps.length)] * _day;
        } else {
          log.now = max(real, log.now - 5 * _day + r.nextInt(2000));
        }
        final e = entities[r.nextInt(entities.length)];
        if (r.nextInt(3) == 0) {
          // A peer stamp up to 7 days ahead, often colliding in millis
          // with stamps already held.
          final held = log.ops.isEmpty
              ? null
              : log.ops[r.nextInt(log.ops.length)];
          final ms = held != null && r.nextBool()
              ? held.hlc.millis
              : log.now + r.nextInt(7 * _day);
          final c = held != null && r.nextBool()
              ? held.hlc.counter
              : r.nextInt(4);
          log.peer(e, Hlc(ms, c, _peers[r.nextInt(_peers.length)]));
          continue;
        }
        final floor = log.ops.any((o) => o.entityId == e)
            ? log.newestOf(e)
            : null;
        final op = log.local(e);
        if (floor != null) {
          expect(op.hlc > floor, isTrue, reason: 'seed $seed step $step');
        }
        final own = log.ops.where((o) => o.deviceId == _me).toList();
        expect(
          own.map((o) => o.hlc).toSet().length,
          own.length,
          reason: 'seed $seed step $step: own stamps are unique',
        );
      }
    });
  }
}
