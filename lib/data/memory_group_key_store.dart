// In-memory GroupKeyStore for tests (docs/SPEC.md 5.11). Owner: data.
import 'dart:typed_data';

import '../core/ids.dart';
import 'repositories.dart';
import 'secure_group_key_store.dart' show kGroupKeyLength;

final class MemoryGroupKeyStore implements GroupKeyStore {
  MemoryGroupKeyStore();

  final Map<GroupId, Uint8List> _keys = {};

  @override
  Future<Uint8List?> keyFor(GroupId groupId) async {
    final key = _keys[groupId];
    return key == null ? null : Uint8List.fromList(key);
  }

  @override
  Future<void> put(GroupId groupId, Uint8List key) async {
    if (key.length != kGroupKeyLength) {
      throw ArgumentError.value(
          key.length, 'key', 'group keys are $kGroupKeyLength bytes');
    }
    _keys[groupId] = Uint8List.fromList(key);
  }

  @override
  Future<void> remove(GroupId groupId) async {
    _keys.remove(groupId);
  }

  @override
  Future<Map<GroupId, Uint8List>> all() async => {
        for (final e in _keys.entries) e.key: Uint8List.fromList(e.value),
      };
}
