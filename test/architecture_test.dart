// Enforces the layer import rules of docs/SPEC.md section 3.2 (and 11.5) by
// scanning the source text of every Dart file under lib/.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const String _package = 'settle_up';

/// Imports a file under lib/core may use besides other lib/core files.
const Set<String> _coreAllowedDart = {
  'dart:core',
  'dart:math',
  'dart:convert',
  'dart:collection',
  'dart:typed_data',
};
const Set<String> _coreAllowedPackages = {
  'meta',
  'collection',
  'uuid',
  'unorm_dart', // NFKC for names (NameText), pure Dart
  // Grapheme clusters, as the UI's maxLength counts them: a name is cut
  // to its limit in the same characters (NameText.fit), pure Dart.
  'characters',
};

/// Files under lib/data that the sync and ui layers may import.
const Set<String> _dataContracts = {'data/repositories.dart'};

/// Files under lib/sync that the ui layer may import (frozen contracts only;
/// the concrete classes are constructed in bootstrap.dart / main.dart).
const Set<String> _syncContracts = {
  'sync/sync_engine.dart',
  'sync/transport/transport.dart',
  'sync/pairing/links.dart',
};

/// Files that are allowed to construct concrete implementations.
const Set<String> _compositionRoots = {'main.dart', 'bootstrap.dart'};

final RegExp _directive = RegExp(
  r'''^\s*(import|export)\s+(['"])([^'"]+)\2''',
  multiLine: true,
);

/// A parsed import/export target.
class Target {
  Target.dart(this.uri) : package = null, libPath = null;
  Target.package(this.uri, this.package) : libPath = null;
  Target.local(this.uri, this.libPath) : package = _package;

  /// The URI as written in the source.
  final String uri;

  /// Package name for `package:` URIs (ours included), null for `dart:`.
  final String? package;

  /// Posix path relative to lib/ when the target is inside this package.
  final String? libPath;

  bool get isDart => uri.startsWith('dart:');
  bool get isLocal => libPath != null;

  bool inDir(String dir) => libPath != null && libPath!.startsWith('$dir/');
}

/// Resolves [uri] as written in the file at [fromLibPath] (posix, relative
/// to lib/).
Target resolve(String fromLibPath, String uri) {
  if (uri.startsWith('dart:')) return Target.dart(uri);
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    final pkg = slash < 0 ? rest : rest.substring(0, slash);
    if (pkg == _package) {
      return Target.local(uri, p.posix.normalize(rest.substring(slash + 1)));
    }
    return Target.package(uri, pkg);
  }
  final joined = p.posix.normalize(
    p.posix.join(p.posix.dirname(fromLibPath), uri),
  );
  return Target.local(uri, joined);
}

/// Returns a human-readable violation for every import/export in [source]
/// (the file at [libPath], posix, relative to lib/) that breaks section 3.2.
List<String> violations(String libPath, String source) {
  final out = <String>[];
  for (final m in _directive.allMatches(source)) {
    final t = resolve(libPath, m.group(3)!);
    final reason = _check(libPath, t);
    if (reason != null) out.add('lib/$libPath: ${t.uri} ($reason)');
  }
  return out;
}

String? _check(String from, Target t) {
  if (t.isLocal && t.libPath!.startsWith('../')) {
    return 'points outside lib/';
  }
  if (_compositionRoots.contains(from)) return null;
  final layer = from.split('/').first;
  switch (layer) {
    case 'core':
      if (t.isDart) {
        return _coreAllowedDart.contains(t.uri)
            ? null
            : 'core may only use pure Dart libraries';
      }
      if (t.isLocal) {
        return t.inDir('core') ? null : 'core may not import other layers';
      }
      return _coreAllowedPackages.contains(t.package)
          ? null
          : 'core may only use package:meta, collection, uuid, unorm_dart '
              'and characters';
    case 'data':
      if (_isFlutterUi(t)) return 'data may not import Flutter UI libraries';
      if (t.inDir('sync') || t.inDir('ui') || t.inDir('theme')) {
        return 'data may only depend on core';
      }
      return null;
    case 'sync':
      if (_isFlutterUi(t)) return 'sync may not import Flutter UI libraries';
      if (t.inDir('ui') || t.inDir('theme')) {
        return 'sync may not import ui or theme';
      }
      if (t.inDir('data') && !_dataContracts.contains(t.libPath)) {
        return 'sync may only import data/repositories.dart';
      }
      return null;
    case 'theme':
      if (t.inDir('data') || t.inDir('sync') || t.inDir('ui')) {
        return 'theme may only depend on core';
      }
      return null;
    case 'ui':
      if (t.inDir('data') && !_dataContracts.contains(t.libPath)) {
        return 'ui may only use the repository interfaces from data';
      }
      if (t.inDir('sync') && !_syncContracts.contains(t.libPath)) {
        return 'ui may only use the frozen sync contracts';
      }
      if (t.isLocal && _compositionRoots.contains(t.libPath)) {
        return 'ui may not import the composition root';
      }
      return null;
    default:
      return 'unexpected top-level location; add it to section 4 first';
  }
}

bool _isFlutterUi(Target t) =>
    t.package == 'flutter' && t.uri != 'package:flutter/foundation.dart';

void main() {
  group('lib/ import rules (SPEC 3.2)', () {
    test('every file under lib/ follows the layer rules', () {
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: 'run from the package root');
      final files = lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      final problems = <String>[];
      for (final f in files) {
        final rel = p.split(p.relative(f.path, from: lib.path)).join('/');
        problems.addAll(violations(rel, f.readAsStringSync()));
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });

  group('rule checker', () {
    void bad(String file, String uri) => expect(
      violations(file, "import '$uri';"),
      hasLength(1),
      reason: '$file must not import $uri',
    );
    void ok(String file, String uri) => expect(
      violations(file, "import '$uri';"),
      isEmpty,
      reason: '$file may import $uri',
    );

    test('core stays pure Dart', () {
      ok('core/ops.dart', 'ids.dart');
      ok('core/reducer/apply.dart', '../models.dart');
      ok('core/money.dart', 'package:meta/meta.dart');
      ok('core/split.dart', 'dart:math');
      ok('core/ids.dart', 'package:settle_up/core/hlc.dart');
      bad('core/money.dart', 'package:flutter/foundation.dart');
      bad('core/money.dart', 'dart:io');
      bad('core/money.dart', 'dart:ui');
      bad('core/money.dart', '../data/repositories.dart');
      bad('core/money.dart', 'package:settle_up/ui/providers.dart');
      bad('core/money.dart', 'package:intl/intl.dart');
    });

    test('data depends on core only', () {
      ok('data/ledger.dart', '../core/models.dart');
      ok('data/sqlite_op_store.dart', 'package:sqlite3/sqlite3.dart');
      ok('data/ledger.dart', 'package:flutter/foundation.dart');
      ok('data/ledger.dart', 'dart:io');
      bad('data/ledger.dart', '../sync/sync_engine.dart');
      bad('data/ledger.dart', '../ui/providers.dart');
      bad('data/ledger.dart', '../theme/tokens.dart');
      bad('data/ledger.dart', 'package:flutter/material.dart');
      bad('data/ledger.dart', 'package:flutter/widgets.dart');
    });

    test('sync sees only the data interfaces', () {
      ok('sync/default_sync_engine.dart', '../data/repositories.dart');
      ok('sync/transport/lan/lan_transport.dart', '../../../core/ids.dart');
      ok(
        'sync/transport/ble/ble_transport.dart',
        '../../platform/permissions.dart',
      );
      bad('sync/default_sync_engine.dart', '../data/ledger.dart');
      bad(
        'sync/default_sync_engine.dart',
        'package:settle_up/data/schema.dart',
      );
      bad('sync/default_sync_engine.dart', '../ui/providers.dart');
      bad('sync/default_sync_engine.dart', '../theme/tokens.dart');
      bad('sync/default_sync_engine.dart', 'package:flutter/material.dart');
    });

    test('theme sees only core', () {
      ok('theme/app_theme.dart', 'package:flutter/material.dart');
      ok('theme/app_theme.dart', 'package:google_fonts/google_fonts.dart');
      ok('theme/app_theme.dart', '../core/money.dart');
      bad('theme/app_theme.dart', '../ui/strings.dart');
      bad('theme/app_theme.dart', '../data/repositories.dart');
      bad('theme/app_theme.dart', '../sync/sync_engine.dart');
    });

    test('ui uses contracts, not implementations', () {
      ok('ui/providers.dart', '../data/repositories.dart');
      ok('ui/providers.dart', '../sync/sync_engine.dart');
      ok(
        'ui/screens/join/join_screen.dart',
        '../../../sync/pairing/links.dart',
      );
      ok('ui/app.dart', '../theme/app_theme.dart');
      bad('ui/providers.dart', '../data/ledger.dart');
      bad('ui/providers.dart', '../sync/default_sync_engine.dart');
      bad('ui/app.dart', '../sync/transport/lan/lan_transport.dart');
      bad('ui/app.dart', '../bootstrap.dart');
    });

    test('composition roots may construct implementations', () {
      ok('bootstrap.dart', 'data/ledger.dart');
      ok('bootstrap.dart', 'sync/transport/lan/lan_transport.dart');
      ok('main.dart', 'bootstrap.dart');
    });

    test('exports, double quotes and show clauses are scanned', () {
      expect(
        violations('core/a.dart', 'export "package:flutter/material.dart";'),
        hasLength(1),
      );
      expect(
        violations(
          'core/a.dart',
          "import 'dart:io'\n    show File;\nimport 'ids.dart';",
        ),
        hasLength(1),
      );
    });
  });
}
