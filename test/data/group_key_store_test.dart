// GroupKeyStore contract, run against both implementations.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/secure_group_key_store.dart';

import 'helpers.dart';

Uint8List key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (seed * 31 + i) % 256));

void main() {
  void contract(String name, GroupKeyStore Function() create) {
    group(name, () {
      late GroupKeyStore keys;
      setUp(() => keys = create());

      test('put, keyFor, all, remove', () async {
        expect(await keys.keyFor(gA), isNull);
        expect(await keys.all(), isEmpty);
        await keys.put(gA, key(1));
        await keys.put(gB, key(2));
        await keys.put(gA, key(3));
        expect(await keys.keyFor(gA), key(3));
        final all = await keys.all();
        expect(all.keys.toSet(), {gA, gB});
        expect(all[gB], key(2));
        await keys.remove(gA);
        await keys.remove('never');
        expect(await keys.keyFor(gA), isNull);
        expect((await keys.all()).keys, [gB]);
      });

      test('only 32-byte keys are accepted', () async {
        expect(() => keys.put(gA, Uint8List(16)), throwsArgumentError);
        expect(await keys.keyFor(gA), isNull);
      });

      test('returned keys are copies', () async {
        final k = key(1);
        await keys.put(gA, k);
        k[0] ^= 0xff;
        (await keys.keyFor(gA))![1] ^= 0xff;
        expect(await keys.keyFor(gA), key(1));
      });
    });
  }

  contract('MemoryGroupKeyStore', MemoryGroupKeyStore.new);
  contract('SecureGroupKeyStore', () {
    FlutterSecureStorage.setMockInitialValues({});
    return SecureGroupKeyStore();
  });

  group('SecureGroupKeyStore storage format', () {
    test('gk.{groupId} -> base64url; other entries and junk ignored',
        () async {
      FlutterSecureStorage.setMockInitialValues({
        'gk.$gB': base64Url.encode(key(2)),
        'gk.short': base64Url.encode([1, 2, 3]),
        'gk.junk': '%%%',
        'unrelated': 'x',
      });
      const storage = FlutterSecureStorage();
      final keys = SecureGroupKeyStore(storage);
      await keys.put(gA, key(1));
      expect(await storage.read(key: 'gk.$gA'), base64Url.encode(key(1)));
      expect((await keys.all()).keys.toSet(), {gA, gB});
      expect(await keys.keyFor('junk'), isNull);
      expect(await keys.keyFor('short'), isNull);
      // Unpadded base64url from another implementation still reads.
      await storage.write(
          key: 'gk.np', value: base64Url.encode(key(5)).replaceAll('=', ''));
      expect(await keys.keyFor('np'), key(5));
    });
  });
}
