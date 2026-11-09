// FROZEN CONTRACT (docs/SPEC.md section 5.1). Owner: core.
import 'package:uuid/uuid.dart';

/// All ids are lowercase canonical UUIDv7 strings (36 chars), generated on
/// the device. Never auto-increment. Typedefs keep JSON trivial.
typedef DeviceId = String;
typedef PersonId = String;
typedef GroupId = String;
typedef MemberId = String;
typedef ExpenseId = String;
typedef OpId = String;

abstract interface class IdGenerator {
  String newId();
}

final class UuidV7Generator implements IdGenerator {
  const UuidV7Generator();
  static const Uuid _uuid = Uuid();

  @override
  String newId() => _uuid.v7();
}

/// Deterministic generator for tests: '00000000-0000-7000-8000-000000000001', ...
final class SequentialIdGenerator implements IdGenerator {
  SequentialIdGenerator([this._next = 1]);
  int _next;

  @override
  String newId() {
    final n = (_next++).toRadixString(16).padLeft(12, '0');
    return '00000000-0000-7000-8000-$n';
  }
}
