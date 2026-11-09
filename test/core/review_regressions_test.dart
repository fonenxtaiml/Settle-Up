// Regression tests for bugs found in the WP-A review. Each test failed
// before its fix.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ops.dart';

import 'helpers.dart';

const g = 'g1';

void main() {
  late FakeDevice alex;

  setUp(() {
    FakeDevice.wallMs = kBaseMs;
    alex = FakeDevice('dev-alex');
  });

  List<Operation> base() => [
        alex.createGroup(g),
        alex.addMember(g, 'a', 'Alex', claimedBy: alex.deviceId),
        alex.addMember(g, 'b', 'Bob'),
        alex.addMember(g, 'c', 'Cat'),
      ];

  group('reducer', () {
    test('two ops with the same HLC converge whatever the arrival order', () {
      // A buggy or hostile device can reuse an HLC. Rule 4 must still give
      // every replica the same winner, or replicas diverge for good.
      final ops = base();
      final e = alex.addExpense(g, 'e1',
          money: equalBlock(900, 'a', ['a', 'b', 'c']));
      final hlc = alex.clock.tick();
      final x = alex.op(g, EntityType.expense, 'e1', OpKind.update,
          {ExpenseFields.description: 'X'},
          hlc: hlc);
      final y = alex.op(g, EntityType.expense, 'e1', OpKind.update,
          {ExpenseFields.description: 'Y'},
          hlc: hlc);
      final r1 = reduce([...ops, e, x, y]);
      final r2 = reduce([...ops, e, y, x]);
      expect(r1.state.toCanonicalJson(), r2.state.toCanonicalJson());
      expect(r1.state.expense('e1')!.description,
          r2.state.expense('e1')!.description);
    });
  });
}
