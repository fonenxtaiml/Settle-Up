// QA DATA-R1: schema version handling of the SQLite op store, and what the
// real startup path (bootstrap.realOverrides) does with an unusual file.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// Transitive dependency of path_provider; test-only mock of the platform.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:settle_up/bootstrap.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const _dev = 'aaaaaaaa-0000-7000-8000-0000000000a1';
const _grp = '00000000-0000-7000-9000-0000000000g1';

Operation _op(int counter) => Operation(
      id: 'op-$counter',
      groupId: _grp,
      deviceId: _dev,
      counter: counter,
      hlc: Hlc(kQaBaseMs + counter, 0, _dev),
      entityType: EntityType.member,
      entityId: 'm1',
      kind: OpKind.update,
      payload: {MemberFields.displayName: 'n$counter'},
    );

final class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = qaTempDir();
    path = p.join(dir.path, 'settle_up.db');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  int countOps() {
    final db = sqlite3.open(path);
    try {
      return db.select('SELECT COUNT(*) FROM ops').first.columnAt(0) as int;
    } finally {
      db.close();
    }
  }

  group('user_version', () {
    test('fresh file: user_version 1, every table present', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.close();
      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(db.userVersion, 1);
      final names = {
        for (final r in db.select('SELECT name FROM sqlite_master'))
          r.columnAt(0) as String
      };
      expect(names, containsAll(['ops', 'vv', 'peer_vv', 'kv', 'sync_records']));
    });

    test('reopening a v1 file is a no-op and keeps data', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.insertAll([_op(1), _op(2)]);
      await s.setKv('k', 'v');
      await s.close();
      for (var i = 0; i < 3; i++) {
        await s.open();
        expect(await s.loadAll(), hasLength(2));
        expect(await s.getKv('k'), 'v');
        await s.close();
      }
    });

    test('newer file (user_version 2) is refused with a clear error and '
        'its data is left untouched', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.insertAll([_op(1), _op(2), _op(3)]);
      await s.setKv(KvKeys.profile, '{"x":1}');
      await s.close();
      final db = sqlite3.open(path)..userVersion = 2;
      // A v2 app might have added a column/table; it must survive too.
      db.execute('CREATE TABLE future_stuff(x INTEGER)');
      db.execute('INSERT INTO future_stuff VALUES (7)');
      db.close();

      final again = SqliteOpStore(path);
      await expectLater(
          again.open(),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('newer'))));
      // Not open, so calls fail fast instead of touching the file.
      await expectLater(again.loadAll(), throwsStateError);

      final check = sqlite3.open(path);
      addTearDown(check.close);
      expect(check.userVersion, 2, reason: 'not downgraded');
      expect(countOps(), 3, reason: 'ops not wiped');
      expect(check.select('SELECT x FROM future_stuff').single.columnAt(0), 7);
    });

    test(
      'user_version 0 with the v1 tables already present is adopted, '
      'not a startup crash',
      () async {
        final s = SqliteOpStore(path);
        await s.open();
        await s.insertAll([_op(1), _op(2)]);
        await s.close();
        final db = sqlite3.open(path)..userVersion = 0;
        db.close();

        final again = SqliteOpStore(path);
        await again.open(); // currently: SqliteException "table ops already exists"
        addTearDown(again.close);
        expect(await again.loadAll(), hasLength(2));
        final check = sqlite3.open(path);
        addTearDown(check.close);
        expect(check.userVersion, 1);
      },
    );

    test('user_version 0 with no tables (empty file) migrates', () async {
      File(path).writeAsBytesSync(const []);
      final s = SqliteOpStore(path);
      await s.open();
      await s.insertAll([_op(1)]);
      expect(await s.loadAll(), hasLength(1));
      await s.close();
    });

    test('a file that is not a database fails open() without being '
        'overwritten', () async {
      File(path).writeAsStringSync('this is not sqlite ' * 100);
      final before = File(path).readAsBytesSync();
      final s = SqliteOpStore(path);
      await expectLater(s.open(), throwsA(anything));
      expect(File(path).readAsBytesSync(), before);
    });
  });

  group('startup path (bootstrap.realOverrides)', () {
    setUp(() {
      PathProviderPlatform.instance = _FakePaths(dir.path);
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('a normal file starts', () async {
      final overrides = await realOverrides();
      expect(overrides, hasLength(3));
    });

    test(
      'a database from a newer app version does not crash startup',
      () async {
        final s = SqliteOpStore(path);
        await s.open();
        await s.insertAll([_op(1)]);
        await s.close();
        final db = sqlite3.open(path)..userVersion = kStoreSchemaVersion + 1;
        db.close();
        // Expected: startup completes (e.g. with an error/read-only state
        // the UI can show) instead of an unhandled exception before runApp.
        await expectLater(realOverrides(), completes);
        expect(countOps(), 1, reason: 'data must not be wiped either');
      },
    );

    test(
      'an unreadable database file does not crash startup',
      () async {
        File(path).writeAsStringSync('garbage ' * 1000);
        await expectLater(realOverrides(), completes);
      },
    );
  });
}
