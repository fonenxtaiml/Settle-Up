// QA PLATFORM round 42 (final regression sweep): what reached the startup
// path since round 39. Ledger.open now reads Sync history through the
// SECURITY-R39-01 bound (codecs.dart _recordedPeerName), and that runs on
// every launch of a phone that synced before. These probes open, through
// the production wiring (realOverrides), a database an earlier build wrote:
// history rows with received names far over the phone-name limit, names
// that are one long word, names that show nothing, lone surrogates and rows
// that do not parse. The app must start (no StartupFailure) and Sync
// history must list every readable row within the limit.
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/bootstrap.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:settle_up/main.dart' as app;
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void _mockPlatform(Directory dir) {
  _messenger.setMockMethodCallHandler(_pathChannel, (call) async => dir.path);
  final values = <String, String>{};
  _messenger.setMockMethodCallHandler(_secureChannel, (call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'read':
        return values[args['key']];
      case 'readAll':
        return values;
      case 'write':
        values[args['key']! as String] = args['value']! as String;
        return null;
      case 'delete':
        values.remove(args['key']);
        return null;
      case 'deleteAll':
        values.clear();
        return null;
      case 'containsKey':
        return values.containsKey(args['key']);
    }
    return null;
  });
}

/// Names an earlier build may have recorded from a peer's HELLO or advert.
final _oldNames = <String>[
  'Pixel 8',
  'A' * 500,
  List.filled(120, 'Riya').join(' '),
  '\u{1F60E}' * 300,
  'e\u0301' * 200, // decomposed: normalising composes it
  '\u200b\u200b', // shows nothing
  'Pixel \ud800 8', // lone surrogate
  '\u202eevil phone name\u202c',
  '',
];

Future<void> _seedOldHistory(String path) async {
  final store = SqliteOpStore(path);
  await store.open();
  final base = DateTime.utc(2026, 11, 1, 12);
  for (var i = 0; i < _oldNames.length; i++) {
    await store.addSyncRecord(
      SyncRecord(
        id: 'r$i',
        peerName: _oldNames[i],
        transport: TransportKind.values[i % TransportKind.values.length],
        startedAt: base.add(Duration(minutes: i)),
        endedAt: base.add(Duration(minutes: i, seconds: 5)),
        sentOps: i,
        receivedOps: i,
        groupIds: const [],
        outcome: SyncOutcome.completed,
      ),
    );
  }
  await store.close();
  // Rows that do not parse: dropped, never a startup failure.
  final db = sql.sqlite3.open(path);
  try {
    final at = base.add(const Duration(hours: 1)).millisecondsSinceEpoch;
    db.execute(
      'INSERT INTO sync_records(id, started_at, json) VALUES (?, ?, ?)',
      ['bad1', at, '{"id":"bad1","peerName":42}'],
    );
    db.execute(
      'INSERT INTO sync_records(id, started_at, json) VALUES (?, ?, ?)',
      ['bad2', at + 1, 'not json'],
    );
  } finally {
    db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('qa_platform_r42_');
  });
  tearDown(() {
    _messenger.setMockMethodCallHandler(_pathChannel, null);
    _messenger.setMockMethodCallHandler(_secureChannel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  test('an earlier build\'s history with over-long received names opens, '
      'bounded to the phone-name limit', () async {
    _mockPlatform(tmp);
    await _seedOldHistory('${tmp.path}/settle_up.db');

    final overrides = await realOverrides();
    // Three real overrides, no StartupFailure.
    expect(overrides, hasLength(3));
    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    final ledger = container.read(ledgerRepositoryProvider) as Ledger;
    final records = await ledger.watchSyncRecords().first;

    expect(records.map((r) => r.id), isNot(contains('bad1')));
    expect(records.map((r) => r.id), isNot(contains('bad2')));
    expect(records, hasLength(_oldNames.length));
    for (final r in records) {
      expect(
        r.peerName.characters.length,
        lessThanOrEqualTo(NameText.maxLength),
        reason: '${r.id}: ${r.peerName.length} code units',
      );
      expect(
        r.peerName.length,
        lessThanOrEqualTo(NameText.maxLength * NameText.unitsPerChar),
        reason: r.id,
      );
    }
    expect(records.firstWhere((r) => r.id == 'r0').peerName, 'Pixel 8');
  });

  testWidgets('main() starts on that database and shows no startup error', (
    tester,
  ) async {
    _mockPlatform(tmp);
    await tester.runAsync(() => _seedOldHistory('${tmp.path}/settle_up.db'));
    Object? thrown;
    await tester.runAsync(() async {
      try {
        await app.main();
      } catch (e) {
        thrown = e;
      }
    });
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(thrown, isNull);
    expect(tester.takeException(), isNull);
    expect(find.text(S.startupTitle), findsNothing);
  });
}
