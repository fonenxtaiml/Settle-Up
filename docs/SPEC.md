# Settle Up: build specification (MVP)

Status: **frozen for the parallel build**. Date: 2026-11-09. Owner: tech lead.
Inputs: `docs/research/splitwise.md`, `docs/research/offline-sync.md`, `docs/design/DESIGN.md`.
Toolchain verified in this repo's sandbox: **Flutter 3.47.9 (stable), Dart 3.13.7**. The dependency set in section 2 was resolved with `flutter pub get`, the contracts in section 5 pass `flutter analyze` with zero issues, and `package:sqlite3` was checked to run under `flutter test` on the Linux host.

---

## 0. How to use this document

1. **Section 5 is the frozen contract.** Every block headed `FILE:` is copied verbatim into that path in Phase 0 (section 13). After that, the signatures, field names, JSON keys and enum names in those files must not change without the tech lead's sign-off, because other work packages compile against them. Owners replace only the `throw UnimplementedError()` bodies, and may add private members, new files and helpers inside their own directories.
2. **Each work package owns directories** (section 4). You write only inside your own directories and your own `test/` subfolder. If you need something from another package that is not in the contract, write a fake in your test folder and raise it with the tech lead. Do not edit the other package.
3. **`pubspec.yaml`, `analysis_options.yaml`, `android/`, `ios/` and `lib/main.dart`** have single owners (section 4). Nobody else edits them. All dependencies are added at once in Phase 0, so no package needs a pubspec edit.
4. Definition of done for every package: `flutter analyze` is clean (no infos either), `flutter test` is green, there are no `print` calls (use `dart:developer` `log`), and no `TODO` remains in public API.
5. Money is **integer minor units + ISO 4217 code** everywhere. A `double` may appear only inside `MoneyFormat.format` (display) and in UI geometry (vial position). Any other `double` near money is a review blocker.

---

## 1. MVP scope

Priorities come from `docs/research/splitwise.md` section 13. P0 = must ship in this build. P1 = build only if P0 is done and green (each P1 item is independent and can be dropped).

### 1.1 In (P0)

| # | Feature | Notes |
|---|---|---|
| 1 | Local profile: name, home currency. No account. | Onboarding (DESIGN 6.1). Device identity is created on first launch. |
| 2 | Groups: create, edit, archive, delete (tombstone). Types trip/home/couple/other, default currency, emoji. | Members are local "people" added by name, or re-used from other groups (same `personId`). |
| 3 | Friends / non-group 1:1 balances | Implemented as a hidden `GroupType.direct` group per pair. The Friends tab aggregates people across all groups. |
| 4 | Add / edit / delete (soft) / restore expense: description, amount, currency, date, category, notes, payer(s). | Undo on add and on delete. |
| 5 | Split methods **equal, exact, percent, shares, adjustment**, with a live remainder and deterministic rounding. | Section 6.1. |
| 6 | **Multiple payers** using the same split methods as the owed side (equal, exact, percent, shares). | This fixes a Splitwise complaint. |
| 7 | Balances per group, per person and overall, **per currency**. No conversion. | Section 6.6. |
| 8 | **Simplify debts** toggle per group (greedy min cash flow, deterministic). "Original" pairwise view when it is off. | Section 6.4. |
| 9 | Settle up / record a payment (cash, bank, UPI, other as labels only), partial and over-payment, recorded by either side. | Signature "bubble" animation (DESIGN 4.4). |
| 10 | Activity feed per group and global, with edit history, restore deleted, and conflict notes. | Rendered from the op log (`ActivityBuilder`). Sync sessions appear as rows. |
| 11 | Categories (two-level taxonomy) with keyword auto-suggest. | Section 5.9. |
| 12 | **Wi-Fi hotspot / LAN sync**: TCP + mDNS discovery + hotspot gateway probe + QR connect. | Section 8. |
| 13 | **Bluetooth sync**: Nearby Connections (Android to Android) and BLE GATT (Android to Android, Android to iOS). Same protocol. | Section 8. |
| 14 | **QR invite to join a group** (carries group id + key), "Which one are you?" member claim. | Section 8.6. |
| 15 | Local search across expenses (in-memory, description + notes + category label + member names). | No FTS needed at MVP sizes. |
| 16 | CSV export of a group (share sheet). | `CsvExport.group` + `share_plus`. |
| 17 | Light/dark Material 3 theme per DESIGN.md, bundled fonts, offline only. | No runtime font fetching. |

### 1.2 Stretch (P1, in priority order)

1. Live mode: keep a session open on the Sync screen and push new ops immediately (`SyncEngine.liveMode`). The protocol supports it already (section 8.8).
2. Android LocalOnlyHotspot from inside the app (`wifi_iot`) with a Wi-Fi QR code. Until then, the host screen links to system hotspot settings (`app_settings`).
3. SAS pairing for "Unknown phone [Pair]" over Bluetooth with no camera (section 8.7.3). In P0, a Bluetooth peer without shared groups shows "Scan their QR code to join a group" instead.
4. Splitwise CSV import.

### 1.3 Explicitly out of this build

Cloud backend, accounts and multi-device-per-person sync ("Already use Settle Up on another phone? Sync it" shows "Coming soon"); itemized/receipt split; receipt photos and blob transfer (`BLOB_REQ`/`BLOB` are reserved message types only); OCR; recurring expenses; comments; local notifications; currency conversion and FX rates; charts; payment handles and deep links (UPI intents); reminders beyond a plain share-sheet text; "ready to settle" and "close trip"; Ed25519 op signatures; group key rotation on member removal; background sync and foreground services; JSON backup/restore; localization (English only, but all strings go through one file, `lib/ui/strings.dart`, so it can be localized later); web/desktop targets; Wi-Fi Direct; classic Bluetooth RFCOMM.

---

## 2. Tech stack

### 2.1 Decisions

| Concern | Choice | Why |
|---|---|---|
| Language/SDK | Flutter 3.47.9 / Dart 3.13.7 (`environment: sdk ^3.13.7, flutter >=3.47.0`) | What the repo was scaffolded with. `google_fonts` 9 needs it. |
| State management | **Riverpod 3 (`flutter_riverpod` ^3.5.0), no code generation** | `Provider`, `StreamProvider`, `Provider.family`, `Notifier`/`NotifierProvider` only. No `riverpod_generator`, no `legacy.dart` imports (`StateProvider`/`StateNotifier` are banned). |
| Local DB | **`sqlite3` ^3.9.1 used directly, NO drift, NO code generation** | The op log is the only durable state and it is append-only. Materialized state is folded in memory by the pure-Dart reducer (section 7), so we need about 6 SQL statements, not an ORM. That removes `build_runner` from the parallel build (no generated files to conflict on). `sqlite3` 3.x bundles SQLite through Dart build hooks (no `sqlite3_flutter_libs`). It works in `flutter test` on Linux. SQLite runs synchronously on the main isolate; the expected sizes (≤ 20k ops) make this fine. Moving it to an isolate later is internal to `lib/data`. |
| Routing | `go_router` ^18.1.3 with `StatefulShellRoute.indexedStack` for the 3-tab shell | |
| IDs | `uuid` ^4.6.0, `Uuid().v7()` | Time-ordered, Postgres friendly. |
| Crypto | `cryptography` ^2.9.0 + `cryptography_flutter` ^2.3.4 | X25519, HKDF-SHA256, HMAC-SHA256, AES-256-GCM, SHA-256. In tests use `Cryptography.instance` pure-Dart implementations (`cryptography_flutter` only accelerates on device). |
| Secrets | `flutter_secure_storage` ^11.2.0 | Group keys only. |
| LAN | `dart:io` `ServerSocket`/`Socket`, `bonsoir` `>=7.1.5 <7.1.6` (mDNS), `network_info_plus` `>=8.2.1 <8.2.2` (gateway IP) | **Pinned below the latest on purpose:** `bonsoir` 7.1.6 and `network_info_plus` 8.2.2 pull `dbus` ^0.8 (through their Linux implementations), which conflicts with `bluetooth_low_energy` 6.2.1 (`bluez` → `dbus` ^0.7). Do not bump them until `bluetooth_low_energy` moves to `dbus` 0.8. |
| Bluetooth | `nearby_connections` ^4.3.0 (Android only), `bluetooth_low_energy` ^6.2.1 (Android + iOS, central and peripheral) | `flutter_blue_plus` is rejected (central only, and its license needs a paid tier for for-profit use). |
| Permissions | `permission_handler` ^13.0.2; `app_settings` ^9.0.1 to open Bluetooth/hotspot settings | |
| QR | `qr_flutter` ^4.1.0 (render), `mobile_scanner` ^7.5.0 (scan) | |
| Device name | `device_info_plus` ^13.3.0 | Default "Pixel 8" style names. |
| Share/CSV | `share_plus` ^13.3.1 | |
| Fonts | `google_fonts` ^9.0.0 with bundled TTFs and `allowRuntimeFetching = false` | DESIGN 3.2. |
| Formatting | `intl` ^0.20.2 (resolves 0.20.3) | |
| Utilities | `collection` ^1.19.1 (`HeapPriorityQueue`, deep equality), `meta` ^1.18.3, `path` ^1.9.1, `path_provider` ^2.1.6 | `collection`, `meta`, `path` are pinned by the Flutter SDK. |
| Testing | `flutter_test` only. Property tests use a seeded `math.Random` (no `glados`: it does not support Dart 3). | |
| Lints | `flutter_lints` ^6.0.0 plus the rules in 2.3 | |

### 2.2 `pubspec.yaml` (Phase 0, owner: integrator; nobody else edits it)

```yaml
name: settle_up
description: "Offline-first expense splitting"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.13.7
  flutter: ">=3.47.0"

dependencies:
  flutter:
    sdk: flutter
  app_settings: ^9.0.1
  bluetooth_low_energy: ^6.2.1
  bonsoir: ">=7.1.5 <7.1.6"          # see 2.1: dbus conflict
  collection: ^1.19.1
  cryptography: ^2.9.0
  cryptography_flutter: ^2.3.4
  device_info_plus: ^13.3.0
  flutter_riverpod: ^3.5.0
  flutter_secure_storage: ^11.2.0
  go_router: ^18.1.3
  google_fonts: ^9.0.0
  intl: ^0.20.2
  meta: ^1.18.3
  mobile_scanner: ^7.5.0
  nearby_connections: ^4.3.0
  network_info_plus: ">=8.2.1 <8.2.2"  # see 2.1: dbus conflict
  path: ^1.9.1
  path_provider: ^2.1.6
  permission_handler: ^13.0.2
  qr_flutter: ^4.1.0
  share_plus: ^13.3.1
  sqlite3: ^3.9.1
  uuid: ^4.6.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0

flutter:
  uses-material-design: true
  assets:
    - assets/google_fonts/
```

`cupertino_icons` is removed (no Cupertino icons are used). Resolved versions on 2026-11-09: riverpod 3.5.0, go_router 18.1.3, sqlite3 3.9.1 (SQLite 3.54.1), bonsoir 7.1.5, network_info_plus 8.2.1, bluetooth_low_energy 6.2.1, nearby_connections 4.3.0, mobile_scanner 7.5.0, google_fonts 9.0.0, intl 0.20.3, cryptography 2.9.0.

### 2.3 `analysis_options.yaml` (owner: integrator)

Keep the existing file and add:

```yaml
analyzer:
  language:
    strict-casts: true
    strict-raw-types: true
linter:
  rules:
    - avoid_print
    - prefer_single_quotes
    - prefer_final_locals
    - unawaited_futures
    - always_declare_return_types
    - avoid_dynamic_calls
```

`test/architecture_test.dart` (owner: integrator) enforces the import rules of section 3.2 by scanning `lib/` source text.

---

## 3. Architecture

### 3.1 Layers and data flow

```text
            ┌───────────────────────────── lib/ui + lib/theme ─────────────────────────────┐
            │ screens, widgets, router, providers (Riverpod)                               │
            └───────────▲──────────────────────────────▲──────────────────────────────────┘
       LedgerRepository │ watch()/commands              │ SyncEngine
                        │                               │
┌──────────── lib/data ─┴────────────┐      ┌────────── lib/sync ───────────────────────────┐
│ Ledger (implements LedgerRepository│◄─────┤ DefaultSyncEngine ─ SyncSession (state machine)│
│   AND SyncStore)                   │ Sync │   crypto (handshake, AEAD)  codec (frames)     │
│ OpStore (sqlite3)  GroupKeyStore   │ Store│   transports: LAN(TCP+mDNS) Nearby  BLE  Memory│
│ SettingsRepository                 │      │   pairing links (QR)                            │
└──────────────▲─────────────────────┘      └──────────────▲─────────────────────────────────┘
               │ uses                                       │ uses
┌──────────────┴─────────────────────── lib/core (pure Dart) ┴─────────────────────────────────┐
│ ids, money, hlc, version vector, models, ops, LedgerReducer, split, balances, simplify,      │
│ activity, categories, csv                                                                     │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Local write:** UI calls `LedgerRepository.addExpense(draft)` → Ledger validates, computes the money block (`SplitCalculator`), ticks the HLC, takes the next counter for (group, this device), builds an `Operation` → `OpStore.insertAll([op])` (one SQLite transaction) → `LedgerReducer.apply(op)` → emits a new `LedgerSnapshot` → `ledgerProvider` rebuilds the screens. The op is also emitted on `SyncStore.localOps` for live push.

**Remote write:** a sync session receives an `OPS` batch → `SyncStore.applyRemote(groupId, ops)` → same path (insert, `HlcClock.receive(max hlc)`, reducer, snapshot).

**Startup:** open the store → `loadAll()` → `reducer.applyAll(ops)` → restore the HLC (`kv['hlc.last']` merged with the max own-op HLC) → first snapshot.

Balances, simplified debts and summaries are **never stored or synced**. They are pure functions of the snapshot, computed in providers.

### 3.2 Import rules (enforced by `test/architecture_test.dart`)

| Directory | May import | Must not import |
|---|---|---|
| `lib/core/**` | `dart:core`, `dart:math`, `dart:convert`, `dart:collection`, `dart:typed_data`, `package:meta`, `package:collection`, `package:uuid` | `package:flutter/*`, `dart:io`, `dart:ui`, anything in `lib/data`, `lib/sync`, `lib/ui`, `lib/theme` |
| `lib/data/**` | core, `dart:io`, `sqlite3`, `flutter_secure_storage`, `device_info_plus`, `path`, `path_provider`, `flutter/foundation.dart` | `lib/sync`, `lib/ui`, `lib/theme`, `flutter/material.dart`, `flutter/widgets.dart` |
| `lib/sync/**` | core, `lib/data/repositories.dart` (interfaces only), `dart:io`, crypto, transport and permission packages | `lib/data/**` other than `repositories.dart`, `lib/ui`, `lib/theme`, `flutter/material.dart` |
| `lib/theme/**` | `flutter/material.dart`, `google_fonts`, `lib/core` | data, sync, ui |
| `lib/ui/**` | everything above | concrete implementations in data/sync (only `lib/bootstrap.dart` and `lib/main.dart` construct them) |

---

## 4. Folder structure and ownership

```text
lib/
  main.dart                     [WP-F] runApp(ProviderScope(overrides: await bootstrap(), child: SettleUpApp()))
  bootstrap.dart                [WP-F] constructs concrete classes (section 4.2) and returns overrides
  core/                         [WP-A] pure Dart
    ids.dart  money.dart  currencies_data.dart  hlc.dart  version_vector.dart
    models.dart  ops.dart  ledger_state.dart  reducer/ (private impl files)
    split.dart  balances.dart  simplify.dart  activity.dart  categories.dart  csv_export.dart
  data/                         [WP-B]
    repositories.dart           (frozen interfaces)
    sqlite_op_store.dart  memory_op_store.dart  schema.dart
    secure_group_key_store.dart  memory_group_key_store.dart
    kv_settings_repository.dart  ledger.dart  op_factory.dart
  sync/                         [WP-C] protocol + engine + crypto + pairing; [WP-D] transports
    sync_engine.dart            (frozen API)                         [WP-C]
    default_sync_engine.dart  nearby_registry.dart                   [WP-C]
    protocol/  messages.dart codec.dart session.dart batching.dart   [WP-C]
    crypto/    handshake.dart aead.dart tokens.dart                  [WP-C]
    pairing/   links.dart (frozen)                                   [WP-C]
    transport/ transport.dart (frozen)  memory_transport.dart        [WP-C]
    transport/lan/     lan_transport.dart tcp_framing.dart mdns.dart gateway_probe.dart   [WP-D1]
    transport/nearby/  nearby_transport.dart                                              [WP-D2]
    transport/ble/     ble_transport.dart ble_chunker.dart ble_uuids.dart                 [WP-D2]
    platform/  permissions.dart  (permission_handler wrapper per transport)               [WP-D1]
  theme/                        [WP-E]  tokens.dart app_theme.dart (DESIGN 8.1, 8.2 verbatim)
  ui/
    providers.dart              (frozen)                             [WP-F]
    strings.dart                all user-facing copy (DESIGN 7)      [WP-F]
    app.dart router.dart                                             [WP-F]
    format/  money_format.dart (frozen) dates.dart                   [WP-E]
    widgets/ widgets.dart (frozen barrel) + one file per widget      [WP-E]
    screens/ onboarding/ home/ group/ expense/ settle/ activity/
             sync/ person/ settings/ search/ join/                   [WP-F]
    dev/     fake_ledger.dart fake_sync_engine.dart seed_data.dart   [WP-F]
assets/google_fonts/            [WP-E]  Atkinson Hyperlegible Next 400/600/700/800 + OFL.txt
test/
  core/ [WP-A]  data/ [WP-B]  sync/ [WP-C]  sync/lan/ [WP-D1]  sync/bluetooth/ [WP-D2]
  theme/ ui/widgets/ [WP-E]  ui/screens/ [WP-F]  architecture_test.dart [integrator]
android/ ios/                   [WP-D1] permissions, minSdk, Info.plist (section 9)
pubspec.yaml analysis_options.yaml README.md   [integrator]
```

### 4.1 Work packages

| WP | Name | Owns | Depends on (contract only) | Deliverables |
|---|---|---|---|---|
| A | core | `lib/core`, `test/core` | none | All `UnimplementedError` bodies in core; full ISO currency table; category taxonomy; reducer; split, balances, simplify, activity, CSV; tests in section 11.1, including the convergence property test. |
| B | data | `lib/data`, `test/data` | core | `SqliteOpStore`, `MemoryOpStore`, key stores, `KvSettingsRepository`, `Ledger` (implements `LedgerRepository` + `SyncStore`). Tests 11.2. |
| C | sync-core | `lib/sync` except `transport/lan`, `transport/nearby`, `transport/ble`, `platform`; `test/sync` | core, `data/repositories.dart` | Codec, crypto handshake, session state machine, `DefaultSyncEngine`, `MemoryTransport`, discovery merge, links. Tests 11.3 (engine end-to-end over `MemoryTransport`). |
| D1 | LAN transport + platform | `lib/sync/transport/lan`, `lib/sync/platform`, `android/`, `ios/`, `test/sync/lan` | transport contract | `LanTransport` (TCP server/client, framing, mDNS, gateway probe, interface addresses), permissions wrapper, manifests (section 9). Loopback socket tests. |
| D2 | Bluetooth transports | `lib/sync/transport/nearby`, `lib/sync/transport/ble`, `test/sync/bluetooth` | transport contract, permissions wrapper API (8.10) | `NearbyTransport`, `BleTransport`, BLE chunker (pure, unit tested). |
| E | ui-kit | `lib/theme`, `lib/ui/widgets`, `lib/ui/format`, `assets/`, `test/theme`, `test/ui/widgets` | core models | Theme (DESIGN 8 verbatim), fonts, every widget in 5.15, `MoneyFormat`, `dates.dart`. Widget tests in light/dark at text scale 1.0 and 2.0. |
| F | ui-screens | `lib/ui` except widgets/format, `lib/main.dart`, `lib/bootstrap.dart`, `test/ui/screens` | providers, widgets contract, repositories, sync engine API | Router, every screen in section 10, fakes for development, bootstrap, widget smoke tests 11.4. |

### 4.2 Concrete class names (so bootstrap and tests agree)

```dart
// lib/data
SqliteOpStore(String path)                       // implements OpStore; ':memory:' allowed
MemoryOpStore()                                   // implements OpStore
SecureGroupKeyStore([FlutterSecureStorage? storage])
MemoryGroupKeyStore()
KvSettingsRepository.open(OpStore store, {required String defaultDeviceName, IdGenerator ids = const UuidV7Generator()})  // static Future<KvSettingsRepository>
Ledger.open({required OpStore store, required GroupKeyStore keys, required SettingsRepository settings,
            IdGenerator ids = const UuidV7Generator(), int Function()? nowMillis})          // static Future<Ledger>; implements LedgerRepository, SyncStore
Ledger.close()

// lib/sync
DefaultSyncEngine({required SyncStore store, required List<SyncTransport> transports,
                   SyncClock? clock /* test hook: now() */})
LanTransport({int port = 52741, NearbyPermissions? permissions})
NearbyTransport({NearbyPermissions? permissions})   // Android only; availability()=unsupported elsewhere
BleTransport({NearbyPermissions? permissions})
MemoryTransportHub()  +  MemoryTransport(MemoryTransportHub hub, {required TransportKind kind, required String address, int maxFrameBytes = 1 << 20})
NearbyPermissions()                                  // lib/sync/platform/permissions.dart
```

Reference `bootstrap.dart` (WP-F writes it; this is the shape):

```dart
Future<List<Override>> bootstrap() async {
  FlutterCryptography.enable(); // native AES-GCM/X25519 on device (tests use pure Dart)
  final dir = await getApplicationSupportDirectory();
  final store = SqliteOpStore(p.join(dir.path, 'settle_up.db'));
  await store.open();
  final info = await DeviceInfoPlugin().deviceInfo; // model name for the default device name
  final settings = await KvSettingsRepository.open(store, defaultDeviceName: _deviceName(info));
  final ledger = await Ledger.open(store: store, keys: SecureGroupKeyStore(), settings: settings);
  final permissions = NearbyPermissions();
  final engine = DefaultSyncEngine(store: ledger, transports: [
    LanTransport(permissions: permissions),
    if (Platform.isAndroid) NearbyTransport(permissions: permissions),
    BleTransport(permissions: permissions),
  ]);
  return [
    settingsRepositoryProvider.overrideWithValue(settings),
    ledgerRepositoryProvider.overrideWithValue(ledger),
    syncEngineProvider.overrideWithValue(engine),
  ];
}
```

---

## 5. Frozen contracts

Copy each block to its path verbatim in Phase 0. They compile together (`flutter analyze`: no issues) against the section 2.2 pubspec. Value types (ids, money, HLC, version vector, models, ops, links, `MoneyFormat`, providers) are complete implementations. Algorithms are stubs for their owners.

### 5.1 Identifiers

FILE: `lib/core/ids.dart`

```dart
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
```

### 5.2 Money and currencies

FILE: `lib/core/money.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.2). Owner: core.
// Money is ALWAYS integer minor units + ISO 4217 code. No doubles anywhere.
import 'package:meta/meta.dart';

@immutable
final class Currency {
  const Currency({
    required this.code,
    required this.minorDigits,
    required this.symbol,
    required this.name,
  });

  final String code; // ISO 4217, upper case
  final int minorDigits; // 2 for GBP, 0 for JPY, 3 for KWD
  final String symbol; // display symbol, e.g. '£'
  final String name; // English name, e.g. 'British pound'

  int get minorPerMajor {
    var f = 1;
    for (var i = 0; i < minorDigits; i++) {
      f *= 10;
    }
    return f;
  }
}

abstract final class Currencies {
  /// Owner (core) fills in the full ISO 4217 active list (>= 150 entries),
  /// sorted by code. These four are the minimum the tests rely on.
  static const List<Currency> all = <Currency>[
    Currency(code: 'EUR', minorDigits: 2, symbol: '€', name: 'Euro'),
    Currency(code: 'GBP', minorDigits: 2, symbol: '£', name: 'British pound'),
    Currency(code: 'INR', minorDigits: 2, symbol: '₹', name: 'Indian rupee'),
    Currency(code: 'JPY', minorDigits: 0, symbol: '¥', name: 'Japanese yen'),
    Currency(code: 'USD', minorDigits: 2, symbol: r'$', name: 'US dollar'),
  ];

  static final Map<String, Currency> _byCode = {
    for (final c in all) c.code: c,
  };

  static Currency? tryOf(String code) => _byCode[code.toUpperCase()];

  /// Unknown codes fall back to 2 minor digits with the code as symbol, so
  /// ops from a newer app version never crash an older one.
  static Currency of(String code) =>
      tryOf(code) ??
      Currency(code: code, minorDigits: 2, symbol: code, name: code);
}

@immutable
final class Money implements Comparable<Money> {
  const Money(this.minor, this.currency);

  final int minor;
  final String currency;

  static Money zero(String currency) => Money(0, currency);

  /// Max absolute amount accepted from user input: 9,999,999.99 (2 digits).
  static const int maxMinor = 999999999;

  bool get isZero => minor == 0;
  bool get isPositive => minor > 0;
  bool get isNegative => minor < 0;
  Money abs() => Money(minor.abs(), currency);

  Money operator +(Money other) {
    _check(other);
    return Money(minor + other.minor, currency);
  }

  Money operator -(Money other) {
    _check(other);
    return Money(minor - other.minor, currency);
  }

  Money operator -() => Money(-minor, currency);

  void _check(Money other) {
    if (other.currency != currency) {
      throw ArgumentError('Currency mismatch: $currency vs ${other.currency}');
    }
  }

  @override
  int compareTo(Money other) {
    _check(other);
    return minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() => '$currency $minor';

  Map<String, Object?> toJson() => {'minor': minor, 'currency': currency};

  factory Money.fromJson(Map<String, Object?> json) =>
      Money(json['minor']! as int, json['currency']! as String);

  /// Parses user text ("12", "12.5", "12,50") into minor units of
  /// [currency]. Returns null for empty/invalid input, more fraction digits
  /// than the currency allows, negative values, or values above [maxMinor].
  static int? parseMinor(String text, Currency currency) {
    final t = text.trim().replaceAll(' ', '').replaceAll(',', '.');
    if (t.isEmpty) return null;
    final m = RegExp(r'^(\d+)(?:\.(\d*))?$').firstMatch(t);
    if (m == null) return null;
    final whole = m.group(1)!;
    final frac = m.group(2) ?? '';
    if (frac.length > currency.minorDigits) return null;
    if (whole.length > 12) return null;
    final value = int.parse(whole) * currency.minorPerMajor +
        (frac.isEmpty
            ? 0
            : int.parse(frac.padRight(currency.minorDigits, '0')));
    if (value > maxMinor) return null;
    return value;
  }
}
```

### 5.3 Hybrid logical clock

FILE: `lib/core/hlc.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.3). Owner: core.
import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'ids.dart';

/// Hybrid Logical Clock timestamp. Total order: (millis, counter, deviceId).
/// Encoded form sorts lexicographically in the same order:
///   `000001762700000-001a-{deviceId}` (15 digits, '-', 4 hex, '-', id)
@immutable
final class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.deviceId);

  factory Hlc.zero(DeviceId deviceId) => Hlc(0, 0, deviceId);

  /// Throws FormatException on malformed input.
  factory Hlc.parse(String encoded) {
    final a = encoded.indexOf('-');
    final b = a < 0 ? -1 : encoded.indexOf('-', a + 1);
    if (a != 15 || b != 20 || encoded.length <= 21) {
      throw FormatException('Bad HLC', encoded);
    }
    return Hlc(
      int.parse(encoded.substring(0, a)),
      int.parse(encoded.substring(a + 1, b), radix: 16),
      encoded.substring(b + 1),
    );
  }

  static const int maxCounter = 0xFFFF;

  final int millis; // Unix epoch milliseconds (physical component)
  final int counter; // logical component, 0..0xFFFF
  final DeviceId deviceId; // tiebreak

  String encode() => '${millis.toString().padLeft(15, '0')}-'
      '${counter.toRadixString(16).padLeft(4, '0')}-$deviceId';

  @override
  int compareTo(Hlc other) {
    final c1 = millis.compareTo(other.millis);
    if (c1 != 0) return c1;
    final c2 = counter.compareTo(other.counter);
    if (c2 != 0) return c2;
    return deviceId.compareTo(other.deviceId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(millis, counter, deviceId);

  @override
  String toString() => encode();
}

/// One per device. Not thread-safe; owned by the data layer's Ledger.
final class HlcClock {
  HlcClock({required this.deviceId, Hlc? last, int Function()? nowMillis})
      : _last = last ?? Hlc.zero(deviceId),
        _now = nowMillis ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Remote timestamps further ahead of our wall clock than this are
  /// accepted as data but never adopted by our clock (skew guard).
  static const int maxForwardDriftMs = 60 * 60 * 1000; // 1 hour

  final DeviceId deviceId;
  final int Function() _now;
  Hlc _last;

  /// True once a remote op beyond [maxForwardDriftMs] was observed.
  bool skewDetected = false;

  Hlc get last => _last;

  /// Timestamp for a new local event.
  Hlc tick() {
    final now = _now();
    final l = math.max(_last.millis, now);
    final c = l == _last.millis ? _last.counter + 1 : 0;
    return _last = _normalize(l, c);
  }

  /// Merge a remote timestamp (call once per received batch with its max).
  Hlc receive(Hlc remote) {
    final now = _now();
    if (remote.millis > now + maxForwardDriftMs) {
      skewDetected = true;
      return tick();
    }
    final l = math.max(math.max(_last.millis, remote.millis), now);
    final int c;
    if (l == _last.millis && l == remote.millis) {
      c = math.max(_last.counter, remote.counter) + 1;
    } else if (l == _last.millis) {
      c = _last.counter + 1;
    } else if (l == remote.millis) {
      c = remote.counter + 1;
    } else {
      c = 0;
    }
    return _last = _normalize(l, c);
  }

  Hlc _normalize(int l, int c) =>
      c > Hlc.maxCounter ? Hlc(l + 1, 0, deviceId) : Hlc(l, c, deviceId);
}
```

### 5.4 Version vector

FILE: `lib/core/version_vector.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.4). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';

/// Per group: for each author device, the highest counter N such that this
/// replica holds ALL ops 1..N from that device (contiguous prefix only).
@immutable
final class VersionVector {
  VersionVector([Map<DeviceId, int> entries = const {}])
      : entries = Map.unmodifiable(
          {for (final e in entries.entries) if (e.value > 0) e.key: e.value},
        );

  static final VersionVector empty = VersionVector();

  final Map<DeviceId, int> entries;

  int operator [](DeviceId deviceId) => entries[deviceId] ?? 0;

  bool includes(DeviceId deviceId, int counter) => this[deviceId] >= counter;

  VersionVector withEntry(DeviceId deviceId, int counter) =>
      VersionVector({...entries, deviceId: counter});

  /// Pointwise max.
  VersionVector merge(VersionVector other) {
    final out = Map<DeviceId, int>.of(entries);
    other.entries.forEach((k, v) {
      if (v > (out[k] ?? 0)) out[k] = v;
    });
    return VersionVector(out);
  }

  /// True if this >= other pointwise.
  bool dominates(VersionVector other) =>
      other.entries.entries.every((e) => this[e.key] >= e.value);

  Map<String, int> toJson() => Map.of(entries);

  factory VersionVector.fromJson(Map<String, Object?> json) =>
      VersionVector({for (final e in json.entries) e.key: e.value! as int});

  @override
  bool operator ==(Object other) =>
      other is VersionVector && dominates(other) && other.dominates(this);

  @override
  int get hashCode => Object.hashAllUnordered(
        entries.entries.map((e) => Object.hash(e.key, e.value)),
      );

  @override
  String toString() => 'VV($entries)';
}
```

### 5.5 Domain models

FILE: `lib/core/models.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.5). Owner: core.
// Materialized, immutable domain objects. They are produced ONLY by
// LedgerReducer from ops; UI never constructs Group/Member/Expense itself.
// All DateTimes are UTC with millisecond precision.
import 'package:meta/meta.dart';

import 'hlc.dart';
import 'ids.dart';

DateTime utcFromMillis(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// `direct` = hidden 1:1 group used for non-group expenses with a friend.
enum GroupType { trip, home, couple, other, direct }

enum TransportKind { lan, nearby, ble }

enum ExpenseKind { expense, payment }

enum PaymentMethod { cash, bank, upi, other }

enum AppThemeMode { system, light, dark }

/// How an amount is divided. See SPEC section 6 for `values` semantics.
enum SplitMethod { equal, exact, percent, shares, adjustment }

T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

@immutable
final class Group {
  const Group({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    required this.simplifyDebts,
    required this.createdAt,
    this.emoji,
    this.archived = false,
    this.deletedAt,
  });

  final GroupId id;
  final String name;
  final GroupType type;
  final String currency; // default currency for new expenses
  final bool simplifyDebts;
  final String? emoji;
  final bool archived;
  final DateTime createdAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  bool get isDirect => type == GroupType.direct;
}

@immutable
final class Member {
  const Member({
    required this.id,
    required this.groupId,
    required this.displayName,
    required this.personId,
    required this.createdAt,
    this.deviceId,
    this.mergedInto,
    this.deletedAt,
  });

  final MemberId id;
  final GroupId groupId;
  final String displayName;

  /// Cross-group identity of the human. Same person in two groups => same
  /// personId. A device owner's members carry Profile.personId.
  final PersonId personId;

  /// Device that claimed this member ("this is me"), if any.
  final DeviceId? deviceId;

  /// Set by a merge: balances of this member are attributed to [mergedInto].
  final MemberId? mergedInto;
  final DateTime createdAt;
  final DateTime? deletedAt; // removed from group (tombstone)

  bool get isRemoved => deletedAt != null;
  bool get isPlaceholder => deviceId == null;
}

@immutable
final class SplitSpec {
  const SplitSpec(this.method, this.values);

  /// Equal split among [members] (values are all 1).
  factory SplitSpec.equal(Iterable<MemberId> members) =>
      SplitSpec(SplitMethod.equal, {for (final m in members) m: 1});

  /// One member, the whole amount.
  factory SplitSpec.single(MemberId member, int amountMinor) =>
      SplitSpec(SplitMethod.exact, {member: amountMinor});

  final SplitMethod method;

  /// equal: {member: 1}; exact: {member: minor}; percent: {member: basis
  /// points, sum 10000}; shares: {member: weight >= 1}; adjustment:
  /// {member: signed minor adjustment, 0 = none}. Keys = participants.
  final Map<MemberId, int> values;

  Set<MemberId> get participants => values.keys.toSet();

  Map<String, Object?> toJson() => {'method': method.name, 'values': values};

  factory SplitSpec.fromJson(Map<String, Object?> json) => SplitSpec(
        enumByName(SplitMethod.values, json['method'], SplitMethod.exact),
        {
          for (final e in (json['values']! as Map).entries)
            e.key as String: e.value as int,
        },
      );

  @override
  bool operator ==(Object other) =>
      other is SplitSpec &&
      other.method == method &&
      other.values.length == values.length &&
      other.values.entries.every((e) => values[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
        method,
        Object.hashAllUnordered(
          values.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );
}

/// The atomic LWW "money" field of an expense. Invariant:
/// sum(paid.values) == sum(owed.values) == total, all entries > 0.
@immutable
final class MoneyBlock {
  const MoneyBlock({
    required this.total,
    required this.currency,
    required this.paidBy,
    required this.owedBy,
    required this.paid,
    required this.owed,
  });

  final int total; // minor units, > 0
  final String currency;
  final SplitSpec paidBy; // input spec, kept so the editor can reopen it
  final SplitSpec owedBy;
  final Map<MemberId, int> paid; // computed, zero entries omitted
  final Map<MemberId, int> owed; // computed, zero entries omitted

  bool get isConsistent {
    int sum(Map<MemberId, int> m) => m.values.fold(0, (a, b) => a + b);
    return total > 0 &&
        sum(paid) == total &&
        sum(owed) == total &&
        paid.values.every((v) => v > 0) &&
        owed.values.every((v) => v > 0);
  }

  Map<String, Object?> toJson() => {
        'total': total,
        'currency': currency,
        'paidBy': paidBy.toJson(),
        'owedBy': owedBy.toJson(),
        'paid': paid,
        'owed': owed,
      };

  factory MoneyBlock.fromJson(Map<String, Object?> json) {
    Map<MemberId, int> ints(Object? m) => {
          for (final e in (m! as Map).entries) e.key as String: e.value as int,
        };
    return MoneyBlock(
      total: json['total']! as int,
      currency: json['currency']! as String,
      paidBy: SplitSpec.fromJson(Map<String, Object?>.from(json['paidBy']! as Map)),
      owedBy: SplitSpec.fromJson(Map<String, Object?>.from(json['owedBy']! as Map)),
      paid: ints(json['paid']),
      owed: ints(json['owed']),
    );
  }
}

@immutable
final class Expense {
  const Expense({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.description,
    required this.category,
    required this.date,
    required this.notes,
    required this.money,
    required this.createdBy,
    required this.createdAt,
    required this.updatedHlc,
    this.paymentMethod,
    this.deletedAt,
  });

  final ExpenseId id;
  final GroupId groupId;
  final ExpenseKind kind;
  final String description; // payments: '' (UI renders "Sam paid Priya")
  final String category; // Categories id, payments: 'payment'
  final DateTime date; // when it happened (user editable)
  final String notes;
  final MoneyBlock money;
  final MemberId createdBy;
  final DateTime createdAt;
  final Hlc updatedHlc; // max HLC of all ops applied to this expense
  final PaymentMethod? paymentMethod; // payments only
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  bool get isPayment => kind == ExpenseKind.payment;

  /// Payments only: the single payer / single receiver.
  MemberId get payer => money.paid.keys.first;
  MemberId get receiver => money.owed.keys.first;

  /// Effect on [member]: paid - owed (positive = "you lent").
  int impactFor(MemberId member) =>
      (money.paid[member] ?? 0) - (money.owed[member] ?? 0);
}

/// The local human. Not synced as such; their members carry personId.
@immutable
final class Profile {
  const Profile({
    required this.personId,
    required this.displayName,
    required this.homeCurrency,
  });

  final PersonId personId;
  final String displayName;
  final String homeCurrency;

  Profile copyWith({String? displayName, String? homeCurrency}) => Profile(
        personId: personId,
        displayName: displayName ?? this.displayName,
        homeCurrency: homeCurrency ?? this.homeCurrency,
      );
}

@immutable
final class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.deviceName});
  final DeviceId deviceId; // UUIDv7, created on first launch, never changes
  final String deviceName; // "Alex's Pixel 7", user editable
}

@immutable
final class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.vibration = true,
    this.defaultSplit = SplitMethod.equal,
    this.simplifyByDefault = true,
  });

  final AppThemeMode themeMode;
  final bool vibration;
  final SplitMethod defaultSplit;
  final bool simplifyByDefault;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? vibration,
    SplitMethod? defaultSplit,
    bool? simplifyByDefault,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        vibration: vibration ?? this.vibration,
        defaultSplit: defaultSplit ?? this.defaultSplit,
        simplifyByDefault: simplifyByDefault ?? this.simplifyByDefault,
      );
}

enum SyncOutcome { completed, partial, failed, cancelled }

/// Local history of sync sessions (never synced to peers).
@immutable
final class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.peerName,
    required this.transport,
    required this.startedAt,
    required this.endedAt,
    required this.sentOps,
    required this.receivedOps,
    required this.groupIds,
    required this.outcome,
    this.peerDeviceId,
    this.error,
  });

  final String id;
  final DeviceId? peerDeviceId;
  final String peerName;
  final TransportKind transport;
  final DateTime startedAt;
  final DateTime endedAt;
  final int sentOps;
  final int receivedOps;
  final List<GroupId> groupIds;
  final SyncOutcome outcome;
  final String? error;
}
```

### 5.6 Operation (op-log entry) and field names

FILE: `lib/core/ops.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.6). Owner: core.
// The op log is the source of truth. Wire format == storage format ==
// future cloud format. Field names below are part of the protocol.
import 'package:meta/meta.dart';

import 'hlc.dart';
import 'ids.dart';

const int kSchemaVersion = 1;

enum EntityType { group, member, expense }

/// create: first write of an entity (carries all required fields).
/// update: changed fields only. delete: `{deletedAt: ms}`.
/// restore: {deletedAt: null}. All kinds merge identically (per-field LWW);
/// the kind only drives the activity feed wording.
enum OpKind { create, update, delete, restore }

@immutable
final class Operation {
  const Operation({
    required this.id,
    required this.groupId,
    required this.deviceId,
    required this.counter,
    required this.hlc,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.payload,
    this.schemaVersion = kSchemaVersion,
    this.raw,
  });

  final OpId id; // UUIDv7
  final GroupId groupId; // sync + trust scope
  final DeviceId deviceId; // author device
  final int counter; // per (deviceId, groupId), contiguous from 1
  final Hlc hlc; // hlc.deviceId == deviceId
  final EntityType entityType;
  final String entityId; // for EntityType.group, entityId == groupId
  final OpKind kind;
  final Map<String, Object?> payload; // field -> JSON value (see *Fields)
  final int schemaVersion;

  /// Original JSON, kept only for ops with schemaVersion > kSchemaVersion so
  /// they are stored and relayed byte-for-byte without being understood.
  final Map<String, Object?>? raw;

  bool get isFromNewerSchema => schemaVersion > kSchemaVersion;

  Map<String, Object?> toJson() => raw ?? {
        'id': id,
        'groupId': groupId,
        'deviceId': deviceId,
        'counter': counter,
        'hlc': hlc.encode(),
        'entityType': entityType.name,
        'entityId': entityId,
        'kind': kind.name,
        'payload': payload,
        'schemaVersion': schemaVersion,
      };

  /// Throws FormatException on any malformed field. Unknown entityType or
  /// kind names throw unless schemaVersion > kSchemaVersion; such newer ops
  /// parse with placeholder entityType/kind, keep [raw], are stored and
  /// relayed, and are skipped by the reducer (SPEC 7.6).
  factory Operation.fromJson(Map<String, Object?> json) {
    try {
      final sv = json['schemaVersion'] as int? ?? 1;
      EntityType et = EntityType.group;
      OpKind k = OpKind.update;
      final etName = json['entityType'];
      final kName = json['kind'];
      final etKnown = EntityType.values.where((e) => e.name == etName);
      final kKnown = OpKind.values.where((e) => e.name == kName);
      if (etKnown.isNotEmpty && kKnown.isNotEmpty) {
        et = etKnown.first;
        k = kKnown.first;
      } else if (sv <= kSchemaVersion) {
        throw FormatException('Unknown entityType/kind', '$etName/$kName');
      }
      final op = Operation(
        id: json['id']! as String,
        groupId: json['groupId']! as String,
        deviceId: json['deviceId']! as String,
        counter: json['counter']! as int,
        hlc: Hlc.parse(json['hlc']! as String),
        entityType: et,
        entityId: json['entityId']! as String,
        kind: k,
        payload: Map<String, Object?>.from(json['payload']! as Map),
        schemaVersion: sv,
        raw: sv > kSchemaVersion ? Map<String, Object?>.of(json) : null,
      );
      if (op.counter < 1 || op.hlc.deviceId != op.deviceId) {
        throw const FormatException('Bad counter or hlc device');
      }
      return op;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Bad op: $e');
    }
  }

  @override
  bool operator ==(Object other) => other is Operation && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Op($kind ${entityType.name}:$entityId #$counter@$deviceId $payload)';
}

/// Payload field names. Values are JSON: String, int, bool, null, Map.
abstract final class GroupFields {
  static const name = 'name'; // String
  static const type = 'type'; // GroupType.name
  static const currency = 'currency'; // ISO code
  static const simplifyDebts = 'simplifyDebts'; // bool
  static const emoji = 'emoji'; // String?
  static const archived = 'archived'; // bool
  static const createdAt = 'createdAt'; // int ms, create only
  static const deletedAt = 'deletedAt'; // int? ms
  static const required = [name, type, currency, simplifyDebts, createdAt];
}

abstract final class MemberFields {
  static const displayName = 'displayName'; // String
  static const personId = 'personId'; // String
  static const deviceId = 'deviceId'; // String? (claim)
  static const mergedInto = 'mergedInto'; // String? MemberId
  static const createdAt = 'createdAt'; // int ms, create only
  static const deletedAt = 'deletedAt'; // int? ms
  static const required = [displayName, personId, createdAt];
}

abstract final class ExpenseFields {
  static const kind = 'kind'; // ExpenseKind.name, create only
  static const description = 'description'; // String
  static const category = 'category'; // String category id
  static const date = 'date'; // int ms
  static const notes = 'notes'; // String
  static const money = 'money'; // MoneyBlock.toJson() — ATOMIC register
  static const paymentMethod = 'paymentMethod'; // PaymentMethod.name?
  static const createdBy = 'createdBy'; // MemberId, create only
  static const createdAt = 'createdAt'; // int ms, create only
  static const deletedAt = 'deletedAt'; // int? ms
  static const required = [kind, description, category, date, money, createdBy, createdAt];
}
```

### 5.7 Materialized state and reducer

FILE: `lib/core/ledger_state.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.7). Owner: core.
// Materialized state = deterministic fold of the op SET (order independent).
import 'package:meta/meta.dart';

import 'ids.dart';
import 'models.dart';
import 'ops.dart';

@immutable
final class GroupState {
  const GroupState({
    required this.groupId,
    required this.group,
    required this.members,
    required this.expenses,
  });

  final GroupId groupId;

  /// Null until the group's `create` op has been applied (e.g. right after
  /// joining by invite, before the first sync).
  final Group? group;
  final Map<MemberId, Member> members; // includes removed + merged
  final Map<ExpenseId, Expense> expenses; // includes deleted (tombstones)

  /// Not removed and not merged away. Sorted by displayName, then id.
  List<Member> get activeMembers => throw UnimplementedError();

  /// Non-deleted, consistent expenses AND payments, newest `date` first,
  /// ties by id descending.
  List<Expense> get liveExpenses => throw UnimplementedError();

  /// Follows mergedInto chains (cycle-safe: stops at the smallest id seen).
  MemberId resolve(MemberId memberId) => throw UnimplementedError();

  /// The member whose personId == [personId] (active first), if any.
  Member? memberForPerson(PersonId personId) => throw UnimplementedError();
}

@immutable
final class LedgerState {
  const LedgerState(this.groups);

  static const LedgerState empty = LedgerState({});

  final Map<GroupId, GroupState> groups;

  /// Groups with a create op and not deleted (direct groups included).
  Iterable<GroupState> get visibleGroups => groups.values
      .where((g) => g.group != null && !g.group!.isDeleted);

  Expense? expense(ExpenseId id) {
    for (final g in groups.values) {
      final e = g.expenses[id];
      if (e != null) return e;
    }
    return null;
  }

  /// Canonical, key-sorted JSON of everything materialized (including
  /// tombstones). Two replicas converge iff these are deeply equal.
  Map<String, Object?> toCanonicalJson() => throw UnimplementedError();
}

/// Incremental, idempotent, commutative reducer (SPEC 7).
/// Pure Dart. One instance owned by the data layer's Ledger.
final class LedgerReducer {
  LedgerReducer();

  static const int supportedSchemaVersion = kSchemaVersion;

  /// Applies [op]. Returns true if it changed materialized state. Re-applying
  /// the same op id is a no-op returning false. Ops with schemaVersion >
  /// supportedSchemaVersion are ignored (return false).
  bool apply(Operation op) => throw UnimplementedError();

  /// Applies many; returns ids of entities whose state changed.
  Set<String> applyAll(Iterable<Operation> ops) => throw UnimplementedError();

  /// Immutable snapshot of the current state (safe to hand to the UI).
  LedgerState get state => throw UnimplementedError();
}
```

### 5.7.1 Split calculator (algorithm: 6.1)

FILE: `lib/core/split.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 6.1). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'models.dart';

enum SplitError {
  nonPositiveTotal, // total <= 0 or > Money.maxMinor
  noParticipants,
  sumMismatch, // exact: sum(values) != total
  percentNot100, // percent: sum(bp) != 10000
  zeroWeight, // shares: a weight < 1, or sum == 0
  negativeShare, // any computed share < 0 (adjustment too large, negative exact)
}

final class SplitException implements Exception {
  const SplitException(this.error, [this.message = '']);
  final SplitError error;
  final String message;
  @override
  String toString() => 'SplitException(${error.name}: $message)';
}

/// Live editor feedback. Units: minor for exact/adjustment, basis points for
/// percent, weights for shares, 1 per head for equal.
@immutable
final class SplitCheck {
  const SplitCheck({
    required this.targetUnits,
    required this.assignedUnits,
    required this.error,
    required this.shares,
  });

  final int targetUnits; // exact: total; percent: 10000; others: assigned
  final int assignedUnits;
  final SplitError? error;
  final Map<MemberId, int>? shares; // computed minor amounts when valid

  int get remainingUnits => targetUnits - assignedUnits; // < 0 = too much
  bool get isValid => error == null;
}

abstract final class SplitCalculator {
  /// Per-member minor amounts (zero entries omitted) summing EXACTLY to
  /// [total]. Deterministic on every device. Throws [SplitException].
  static Map<MemberId, int> compute(int total, SplitSpec spec) => throw UnimplementedError();

  /// Never throws; for the live remainder bar.
  static SplitCheck check(int total, SplitSpec spec) => throw UnimplementedError();

  /// Largest-remainder apportionment of [total] by non-negative [weights].
  /// floor(total*w/W) each, then +1 to the largest fractional remainders,
  /// ties broken by member id ascending (String.compareTo).
  static Map<MemberId, int> allocate(int total, Map<MemberId, int> weights) => throw UnimplementedError();

  /// Builds the atomic money block: computes paid (from [paidBy]) and owed
  /// (from [owedBy]). Throws [SplitException].
  static MoneyBlock buildMoneyBlock({
    required int total,
    required String currency,
    required SplitSpec paidBy,
    required SplitSpec owedBy,
  }) =>
      throw UnimplementedError();

  /// Money block for a payment: [from] paid [amount] to [to].
  static MoneyBlock paymentBlock({
    required MemberId from,
    required MemberId to,
    required int amount,
    required String currency,
  }) =>
      throw UnimplementedError();
}
```

### 5.7.2 Balances, simplify, summaries (algorithms: 6.2 to 6.5)

FILE: `lib/core/balances.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md sections 6.2 to 6.5). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'ledger_state.dart';

/// [from] should pay [to] [amount] minor units of [currency].
@immutable
final class Transfer {
  const Transfer({
    required this.from,
    required this.to,
    required this.amount,
    required this.currency,
  });

  final MemberId from;
  final MemberId to;
  final int amount; // > 0
  final String currency;

  @override
  bool operator ==(Object other) =>
      other is Transfer &&
      other.from == from &&
      other.to == to &&
      other.amount == amount &&
      other.currency == currency;

  @override
  int get hashCode => Object.hash(from, to, amount, currency);

  @override
  String toString() => 'Transfer($from -> $to $amount $currency)';
}

/// currency -> member -> net minor (positive = gets back, negative = owes).
typedef NetsByCurrency = Map<String, Map<MemberId, int>>;

abstract final class BalanceCalculator {
  /// Sum of (paid - owed) over liveExpenses (payments included), members
  /// resolved through mergedInto, per currency. Zero entries omitted;
  /// currencies whose nets are all zero omitted. Each currency sums to 0.
  static NetsByCurrency groupNets(GroupState group) => throw UnimplementedError();

  /// "Original" view: who owes whom from actual expenses, netted per pair
  /// and currency (SPEC 6.3). Sorted by currency, from, to.
  static List<Transfer> pairwiseDebts(GroupState group) => throw UnimplementedError();

  /// simplifyDebts ? DebtSimplifier over groupNets : pairwiseDebts.
  static List<Transfer> suggestedTransfers(GroupState group) => throw UnimplementedError();
}

abstract final class DebtSimplifier {
  /// Greedy min-cash-flow with two max-heaps (SPEC 6.4). [nets] must sum
  /// to 0. Deterministic: ties by member id ascending. <= n-1 transfers.
  static List<Transfer> simplify(Map<MemberId, int> nets, String currency) => throw UnimplementedError();
}

@immutable
final class GroupBalanceSummary {
  const GroupBalanceSummary({
    required this.group,
    required this.myMemberId,
    required this.myNet,
    required this.memberCount,
    required this.lastActivityAt,
  });

  final GroupState group;
  final MemberId? myMemberId;
  final Map<String, int> myNet; // currency -> minor, + = I get back
  final int memberCount; // active members
  final DateTime? lastActivityAt; // max expense createdAt/date, else group createdAt

  bool get isSettled => myNet.values.every((v) => v == 0);
}

@immutable
final class PersonBalance {
  const PersonBalance({
    required this.personId,
    required this.displayName,
    required this.net,
    required this.groupIds,
  });

  final PersonId personId;
  final String displayName; // most recently created member's name
  final Map<String, int> net; // + = they owe me, - = I owe them
  final List<GroupId> groupIds; // shared non-deleted groups incl. direct

  bool get isSettled => net.values.every((v) => v == 0);
}

@immutable
final class OverallBalance {
  const OverallBalance({
    required this.net,
    required this.owedToMe,
    required this.iOwe,
  });

  final Map<String, int> net; // owedToMe - iOwe per currency
  final Map<String, int> owedToMe; // sum of positive person balances
  final Map<String, int> iOwe; // sum of |negative| person balances

  static const OverallBalance zero =
      OverallBalance(net: {}, owedToMe: {}, iOwe: {});
}

abstract final class Summaries {
  /// One per visible, non-direct group, unsettled first, then by
  /// lastActivityAt desc.
  static List<GroupBalanceSummary> groups(LedgerState state, PersonId me) => throw UnimplementedError();

  /// Per other person across ALL visible groups (direct included), from
  /// each group's suggestedTransfers between me and them (SPEC 6.5).
  /// Unsettled first, then by displayName.
  static List<PersonBalance> people(LedgerState state, PersonId me) => throw UnimplementedError();

  static OverallBalance overall(LedgerState state, PersonId me) => throw UnimplementedError();

  /// My net in one group (empty map if I am not a member).
  static Map<String, int> myNetInGroup(GroupState group, PersonId me) => throw UnimplementedError();
}
```

### 5.8 Activity feed

FILE: `lib/core/activity.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.8). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'ledger_state.dart';
import 'ops.dart';

enum ActivityKind {
  groupCreated,
  groupEdited,
  groupDeleted,
  memberAdded,
  memberEdited,
  memberRemoved,
  membersMerged,
  memberClaimed,
  expenseAdded,
  expenseEdited,
  expenseDeleted,
  expenseRestored,
  paymentAdded,
  paymentEdited,
  paymentDeleted,
  paymentRestored,
}

@immutable
final class FieldChange {
  const FieldChange(this.before, this.after);
  final Object? before; // JSON value before this op (null if unset)
  final Object? after;
}

@immutable
final class ActivityEntry {
  const ActivityEntry({
    required this.op,
    required this.kind,
    required this.actor,
    required this.changes,
    required this.isLocal,
    required this.isShared,
    required this.supersededBy,
  });

  final Operation op;
  final ActivityKind kind;

  /// Member in op.groupId whose deviceId == op.deviceId, else null
  /// ("Someone on `device name`").
  final MemberId? actor;

  /// Field -> before/after, computed by replaying the entity's earlier ops
  /// in HLC order. For create ops: before == null.
  final Map<String, FieldChange> changes;
  final bool isLocal; // authored on this device
  final bool isShared; // local op already acknowledged by some peer

  /// For `money` LWW conflicts: the op id that overwrote this op's money
  /// value although it was concurrent (UI: "Priya also edited ..."), else null.
  final OpId? supersededBy;

  GroupId get groupId => op.groupId;
  String get entityId => op.entityId;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(op.hlc.millis, isUtc: true);
}

abstract final class ActivityBuilder {
  /// Newest first. [ops] = every stored op (any order). Merge-only ops of
  /// newer schema are skipped. [groupId] null = all groups.
  static List<ActivityEntry> build({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    GroupId? groupId,
  }) =>
      throw UnimplementedError();

  /// Edit history of one entity, oldest first.
  static List<ActivityEntry> historyOf({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    required String entityId,
  }) =>
      throw UnimplementedError();
}
```

### 5.9 Categories

FILE: `lib/core/categories.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.9). Owner: core (icons: ui).
import 'package:meta/meta.dart';

@immutable
final class Category {
  const Category({
    required this.id,
    required this.label,
    this.parentId,
    this.keywords = const [],
  });

  final String id; // stable, dotted: 'food.groceries'; top level: 'food'
  final String label; // 'Groceries'
  final String? parentId; // 'food'
  final List<String> keywords; // lower case, for suggest()
}

abstract final class Categories {
  static const String general = 'general'; // "Uncategorized" fallback
  static const String payment = 'payment'; // reserved for payments

  /// Splitwise-like two-level taxonomy (SPEC 5.9), parents before children.
  static List<Category> get all => throw UnimplementedError();

  /// Unknown ids return the `general` category (never throws).
  static Category byId(String id) => throw UnimplementedError();

  /// Best keyword match on lower-cased word tokens of [description],
  /// longest keyword wins, ties by category id; null if no match.
  static String? suggest(String description) => throw UnimplementedError();
}
```

**Category taxonomy (WP-A implements `Categories.all` exactly with these ids; WP-E maps ids to Material Symbols Rounded icons in `CategoryGlyph.iconFor`):**

| Parent id (label) | Children: id suffix (label) and keywords for `suggest()` |
|---|---|
| `entertainment` (Entertainment) | `.games` (Games: game, games, arcade, bowling), `.movies` (Movies: movie, cinema, film, netflix), `.music` (Music: concert, gig, spotify, music), `.sports` (Sports: gym, football, tennis, match, swim) |
| `food` (Food and drink) | `.dining` (Dining out: dinner, lunch, breakfast, brunch, restaurant, cafe, coffee, pizza, burger, takeaway), `.groceries` (Groceries: grocery, groceries, supermarket, tesco, aldi, lidl, walmart, bigbasket, market), `.liquor` (Liquor: beer, wine, bar, pub, drinks, liquor) |
| `home` (Home) | `.rent` (Rent: rent), `.mortgage` (Mortgage: mortgage), `.household` (Household supplies: detergent, toilet, cleaning supplies, household), `.furniture` (Furniture: furniture, ikea, sofa), `.electronics` (Electronics: tv, laptop, phone case, electronics), `.maintenance` (Maintenance: plumber, repair, electrician), `.pets` (Pets: vet, pet, dog, cat) |
| `life` (Life) | `.childcare` (Childcare: babysitter, nursery, daycare), `.clothing` (Clothing: clothes, shoes, shirt), `.education` (Education: books, course, tuition), `.gifts` (Gifts: gift, present, birthday), `.insurance` (Insurance: insurance), `.medical` (Medical: doctor, pharmacy, medicine, hospital), `.taxes` (Taxes: tax) |
| `transport` (Transportation) | `.bicycle` (Bicycle: bike, cycle), `.bus_train` (Bus and train: bus, train, metro, tube, subway, tram), `.car` (Car: car hire, rental car, toll), `.fuel` (Fuel: petrol, diesel, fuel), `.hotel` (Hotel: hotel, airbnb, hostel, stay), `.parking` (Parking: parking), `.plane` (Plane: flight, flights, airline, plane), `.taxi` (Taxi: taxi, cab, uber, lyft, ola, bolt, rickshaw) |
| `utilities` (Utilities) | `.cleaning` (Cleaning: cleaner, laundry), `.electricity` (Electricity: electricity, power bill), `.gas` (Gas: gas bill), `.heat` (Heat: heating), `.internet` (Internet: internet, wifi, broadband), `.phone` (Phone: phone bill, mobile recharge, recharge), `.trash` (Trash: trash, garbage, bins), `.water` (Water: water bill) |
| `general` (Uncategorized) | none (the default) |
| `payment` (Payment) | none (reserved, never offered in the picker) |

Multi-word keywords match as phrases. `suggest()` lower-cases and tokenizes on non-letters.

### 5.10 CSV export

FILE: `lib/core/csv_export.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.10). Owner: core.
import 'ledger_state.dart';

abstract final class CsvExport {
  /// RFC 4180 CSV, CRLF line ends, UTF-8 (caller adds BOM if wanted).
  /// Columns: Date (yyyy-MM-dd, UTC), Description, Category, Cost (decimal
  /// with the currency's minor digits, '.' separator), Currency, then one
  /// column per active member (display name) holding paid - owed for that
  /// row. Payments included with Category "Payment". Deleted rows excluded.
  /// Rows sorted by date asc, then id.
  static String group(GroupState group) => throw UnimplementedError();
}
```

### 5.11 Repository interfaces (data layer boundary)

FILE: `lib/data/repositories.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.11). Owner: data.
// Interfaces only. Implementations live in lib/data/** (owner: data).
// Dependency rule: lib/data imports lib/core only.
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../core/ids.dart';
import '../core/ledger_state.dart';
import '../core/models.dart';
import '../core/ops.dart';
import '../core/version_vector.dart';

// ---------------------------------------------------------------- storage --

/// Durable op log + small local tables, one SQLite file (`settle_up.db`).
/// Implementations: SqliteOpStore (package:sqlite3), MemoryOpStore (tests).
abstract interface class OpStore {
  Future<void> open();
  Future<void> close();

  /// INSERT OR IGNORE by op id, all in ONE transaction. Returns the ops that
  /// were actually new, in input order. Also advances the stored contiguous
  /// version vector for each affected (group, device).
  Future<List<Operation>> insertAll(List<Operation> ops);

  Future<List<Operation>> loadAll(); // startup; any order
  Future<VersionVector> versionVector(GroupId groupId); // contiguous prefix

  /// Ops in [groupId] with counter > peer[deviceId] (missing devices = 0),
  /// sorted by (deviceId, counter). Includes ops authored by third devices.
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer);

  /// Highest counter stored for (group, device), 0 if none.
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId);

  /// Local-only removal of every row of a group (used by "leave group").
  Future<void> purgeGroup(GroupId groupId);

  /// What peers are known to hold (pointwise max over all peers).
  Future<VersionVector> peerKnowledge(GroupId groupId);
  Future<void> recordPeerKnowledge(
      DeviceId peer, GroupId groupId, VersionVector vv);

  Future<String?> getKv(String key);
  Future<void> setKv(String key, String? value); // null deletes

  Future<void> addSyncRecord(SyncRecord record);
  Future<List<SyncRecord>> syncRecords({int limit = 50}); // newest first
}

/// 32-byte group secrets. Impl: SecureGroupKeyStore (flutter_secure_storage,
/// key `gk.{groupId}`, base64url value), MemoryGroupKeyStore (tests).
abstract interface class GroupKeyStore {
  Future<Uint8List?> keyFor(GroupId groupId);
  Future<void> put(GroupId groupId, Uint8List key);
  Future<void> remove(GroupId groupId);
  Future<Map<GroupId, Uint8List>> all();
}

// --------------------------------------------------------------- settings --

abstract interface class SettingsRepository {
  /// Created on first launch (deviceId = UUIDv7, deviceName from
  /// device_info_plus, e.g. "Pixel 8"), persisted in kv.
  DeviceIdentity get device;
  Profile? get profile; // null until onboarding is done
  AppSettings get settings;

  Stream<Profile?> watchProfile(); // emits current value first
  Stream<AppSettings> watchSettings(); // emits current value first
  Stream<DeviceIdentity> watchDevice(); // emits current value first

  /// First call creates personId (UUIDv7) when [displayName] is set.
  Future<Profile> completeOnboarding({
    required String displayName,
    required String homeCurrency,
  });
  Future<void> updateProfile(Profile profile); // personId must not change
  Future<void> updateSettings(AppSettings settings);
  Future<void> setDeviceName(String name);
}

// ----------------------------------------------------------------- ledger --

@immutable
final class LedgerSnapshot {
  const LedgerSnapshot({
    required this.state,
    required this.ops,
    required this.pendingJoins,
    required this.unsharedOpIds,
    required this.unsharedCounts,
    required this.localDeviceId,
  });

  static LedgerSnapshot empty(DeviceId localDeviceId) => LedgerSnapshot(
        state: LedgerState.empty,
        ops: const [],
        pendingJoins: const {},
        unsharedOpIds: const {},
        unsharedCounts: const {},
        localDeviceId: localDeviceId,
      );

  final LedgerState state;

  /// Every stored op, ascending by HLC. Unmodifiable. Used for activity
  /// and history (ActivityBuilder).
  final List<Operation> ops;

  /// Joined by invite but no group `create` op received yet: id -> name hint.
  final Map<GroupId, String> pendingJoins;

  /// Local ops not yet acknowledged by any peer (OpStore.peerKnowledge).
  final Set<OpId> unsharedOpIds;
  final Map<GroupId, int> unsharedCounts;
  final DeviceId localDeviceId;

  int get totalUnshared => unsharedCounts.values.fold(0, (a, b) => a + b);

  /// Entity ids touched by an unshared op (for the "not yet shared" dot).
  Set<String> get unsharedEntityIds => {
        for (final op in ops)
          if (unsharedOpIds.contains(op.id)) op.entityId,
      };
}

@immutable
final class NewGroup {
  const NewGroup({
    required this.name,
    required this.type,
    required this.currency,
    this.emoji,
    this.simplifyDebts,
    this.newMemberNames = const [],
    this.existingPeople = const [],
  });

  final String name;
  final GroupType type; // never GroupType.direct (use directGroupWith)
  final String currency;
  final String? emoji;
  final bool? simplifyDebts; // null = AppSettings.simplifyByDefault
  final List<String> newMemberNames; // placeholders with fresh personIds
  final List<({PersonId personId, String displayName})> existingPeople;
}

/// Only non-null fields are written (one `update` op).
@immutable
final class GroupPatch {
  const GroupPatch({
    this.name,
    this.type,
    this.currency,
    this.emoji,
    this.simplifyDebts,
    this.archived,
  });

  final String? name;
  final GroupType? type;
  final String? currency;
  final String? emoji;
  final bool? simplifyDebts;
  final bool? archived;
}

@immutable
final class ExpenseDraft {
  const ExpenseDraft({
    required this.groupId,
    required this.description,
    required this.total,
    required this.currency,
    required this.paidBy,
    required this.owedBy,
    required this.category,
    required this.date,
    this.notes = '',
  });

  final GroupId groupId;
  final String description; // trimmed, non-empty
  final int total; // minor units, 1..Money.maxMinor
  final String currency;
  final SplitSpec paidBy;
  final SplitSpec owedBy;
  final String category;
  final DateTime date;
  final String notes;
}

@immutable
final class PaymentDraft {
  const PaymentDraft({
    required this.groupId,
    required this.from,
    required this.to,
    required this.amount,
    required this.currency,
    required this.method,
    required this.date,
    this.notes = '',
  });

  final GroupId groupId;
  final MemberId from; // who paid
  final MemberId to; // who received
  final int amount; // > 0
  final String currency;
  final PaymentMethod method;
  final DateTime date;
  final String notes;
}

enum LedgerErrorCode {
  notOnboarded,
  groupNotFound,
  memberNotFound,
  expenseNotFound,
  invalidInput,
  invalidSplit,
}

final class LedgerException implements Exception {
  const LedgerException(this.code, [this.message = '']);
  final LedgerErrorCode code;
  final String message;
  @override
  String toString() => 'LedgerException(${code.name}: $message)';
}

/// What the UI uses. Every command: validate -> build op(s) with the HLC
/// clock and next counter -> OpStore.insertAll -> reducer.apply -> emit a
/// new snapshot. Throws [LedgerException] (wrapping SplitException as
/// invalidSplit). Commands are serialized (one at a time).
abstract interface class LedgerRepository {
  LedgerSnapshot get current;

  /// Emits [current] immediately, then after every local or remote change.
  Stream<LedgerSnapshot> watch();

  /// Creates group + key (GroupKeyStore) + my member (claimed by this
  /// device) + other members.
  Future<GroupId> createGroup(NewGroup draft);
  Future<void> updateGroup(GroupId groupId, GroupPatch patch);
  Future<void> deleteGroup(GroupId groupId); // tombstone, syncs to everyone

  Future<MemberId> addMember(GroupId groupId,
      {required String displayName, PersonId? personId});
  Future<void> renameMember(GroupId groupId, MemberId memberId, String name);
  Future<void> removeMember(GroupId groupId, MemberId memberId);
  Future<void> mergeMembers(GroupId groupId,
      {required MemberId from, required MemberId into});

  /// "This is me": sets the member's personId to my Profile.personId and
  /// deviceId to this device.
  Future<void> claimMember(GroupId groupId, MemberId memberId);

  /// Finds or creates the direct (1:1) group between me and [personId].
  Future<GroupId> directGroupWith({
    required PersonId personId,
    required String displayName,
    required String currency,
  });

  Future<ExpenseId> addExpense(ExpenseDraft draft);

  /// Writes only fields that differ; money is written as one block.
  Future<void> updateExpense(ExpenseId expenseId, ExpenseDraft draft);
  Future<void> deleteExpense(ExpenseId expenseId);
  Future<void> restoreExpense(ExpenseId expenseId);

  Future<ExpenseId> recordPayment(PaymentDraft draft);
  Future<void> updatePayment(ExpenseId expenseId, PaymentDraft draft);
}

/// What the sync engine uses. Implemented by the same Ledger object.
abstract interface class SyncStore {
  DeviceId get localDeviceId;
  String get localDeviceName;

  /// Groups we hold a key for (pending joins included) -> key.
  Future<Map<GroupId, Uint8List>> groupKeys();

  Future<VersionVector> versionVector(GroupId groupId);
  Future<List<Operation>> opsMissingFor(GroupId groupId, VersionVector peer);

  /// Validates (op.groupId == groupId, key held, parseable, counter >= 1,
  /// hlc.deviceId == deviceId), persists in one transaction, advances the
  /// HLC with the batch max, applies to the reducer, emits a snapshot.
  /// Returns the newly stored ops. Throws FormatException on a bad op
  /// (the whole batch is rejected).
  Future<List<Operation>> applyRemote(GroupId groupId, List<Operation> ops);

  Future<void> recordPeerKnowledge(
      DeviceId peer, GroupId groupId, VersionVector vv);

  /// Every op created locally, as it is committed (for live push).
  Stream<Operation> get localOps;

  /// Stores the key and a pending-join name hint. Idempotent. Returns
  /// false if the group was already known.
  Future<bool> registerJoinedGroup(
      GroupId groupId, Uint8List key, String nameHint);

  Future<void> addSyncRecord(SyncRecord record);
  Stream<List<SyncRecord>> watchSyncRecords(); // newest first, emits first
}
```

### 5.12 SyncTransport and FrameChannel

FILE: `lib/sync/transport/transport.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.12). Owner: sync-core.
// A transport moves opaque FRAMES (already encrypted by the session layer)
// reliably and in order. It knows nothing about ops, groups or crypto.
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/ids.dart';
import '../../core/models.dart';

enum TransportAvailability {
  ready,
  needsPermission,
  permissionPermanentlyDenied,
  radioOff, // Bluetooth or Wi-Fi switched off
  unsupported, // platform/hardware cannot do it
}

/// What we advertise while "visible".
@immutable
final class AdvertiseInfo {
  const AdvertiseInfo({
    required this.deviceId,
    required this.deviceName,
    required this.groupTokens,
  });

  final DeviceId deviceId;
  final String deviceName;

  /// Rotating blinded tokens, one per group we hold (16 hex chars each,
  /// SPEC 8.3). Transports include as many as fit (LAN: all up to 16,
  /// Nearby: up to 4, BLE: in the INFO characteristic, up to 16).
  final List<String> groupTokens;
}

@immutable
final class DiscoveredPeer {
  const DiscoveredPeer({
    required this.kind,
    required this.address,
    required this.name,
    this.deviceIdPrefix,
    this.groupTokens = const {},
  });

  final TransportKind kind;

  /// Transport-specific connect handle: 'host:port' (lan, IPv6 bracketed),
  /// Nearby endpointId (nearby), peripheral UUID string (ble).
  final String address;
  final String name; // device name as advertised ('' if unknown)
  final String? deviceIdPrefix; // first 8 chars of deviceId, if advertised
  final Set<String> groupTokens;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredPeer && other.kind == kind && other.address == address;

  @override
  int get hashCode => Object.hash(kind, address);
}

/// Reliable, ordered, message-oriented, full duplex.
abstract interface class FrameChannel {
  TransportKind get kind;
  String get peerAddress;

  /// Largest frame this channel carries: lan 1 MiB, nearby 32 KiB,
  /// ble 16 KiB. The session negotiates min(local, remote).
  int get maxFrameBytes;

  /// Single-subscription. Each event is exactly one frame as passed to
  /// [send] on the other side. Done when the channel closes; errors on
  /// transport failure.
  Stream<Uint8List> get frames;

  /// Completes when the frame is handed to the OS (applies backpressure).
  /// Throws StateError after close, ArgumentError if > maxFrameBytes.
  Future<void> send(Uint8List frame);

  Future<void> close();
}

abstract interface class SyncTransport {
  TransportKind get kind;

  Future<TransportAvailability> availability();

  /// Requests the runtime permissions this transport needs. Returns the
  /// availability afterwards.
  Future<TransportAvailability> requestPermissions();

  /// Start accepting inbound connections and announcing [info].
  Future<void> startAdvertising(AdvertiseInfo info);
  Future<void> stopAdvertising();

  /// Inbound connections while advertising (broadcast stream).
  Stream<FrameChannel> get inbound;

  /// Scans while listened to; cancelling the subscription stops scanning.
  /// Emits a peer again when its info changes.
  Stream<DiscoveredPeer> discover();

  /// Throws TimeoutException or SocketException-like errors on failure.
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  });

  Future<void> dispose();
}
```

### 5.12.1 Invite and connect links (protocol: 8.6)

FILE: `lib/sync/pairing/links.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 8.6). Owner: sync-core.
// QR / deep-link payloads. Pure Dart, fully specified here.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/ids.dart';

String _b64(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64(String s) =>
    base64Url.decode(s.padRight(s.length + (4 - s.length % 4) % 4, '='));

/// `settleup://join?v=1&g={groupId}&k={b64url key}&n={name}&c={currency}`
/// `&f={inviter device name}[&h={host:port}][&d={inviter deviceId}]`
@immutable
final class InviteLink {
  const InviteLink({
    required this.groupId,
    required this.groupKey,
    required this.groupName,
    required this.currency,
    required this.fromName,
    this.host,
    this.deviceId,
  });

  final GroupId groupId;
  final Uint8List groupKey; // 32 bytes
  final String groupName;
  final String currency;
  final String fromName;
  final String? host; // 'ip:port'
  final DeviceId? deviceId;

  String encode() => Uri(
        scheme: 'settleup',
        host: 'join',
        queryParameters: {
          'v': '1',
          'g': groupId,
          'k': _b64(groupKey),
          'n': groupName,
          'c': currency,
          'f': fromName,
          'h': ?host,
          'd': ?deviceId,
        },
      ).toString();

  /// Returns null if [link] is not a valid v1 invite.
  static InviteLink? tryParse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'settleup' || uri.host != 'join') {
      return null;
    }
    final q = uri.queryParameters;
    if (q['v'] != '1') return null;
    final g = q['g'], k = q['k'], n = q['n'], c = q['c'];
    if (g == null || k == null || n == null || c == null) return null;
    try {
      final key = _unb64(k);
      if (key.length != 32) return null;
      return InviteLink(
        groupId: g,
        groupKey: key,
        groupName: n,
        currency: c,
        fromName: q['f'] ?? '',
        host: q['h'],
        deviceId: q['d'],
      );
    } on FormatException {
      return null;
    }
  }
}

/// `settleup://sync?v=1&h={host:port}[&h={host:port}...]&d={deviceId}`
/// `&n={device name}`
@immutable
final class ConnectLink {
  const ConnectLink({
    required this.hosts,
    required this.deviceId,
    required this.deviceName,
  });

  final List<String> hosts; // tried in order
  final DeviceId deviceId;
  final String deviceName;

  String encode() {
    final parts = <String>[
      'v=1',
      for (final h in hosts) 'h=${Uri.encodeQueryComponent(h)}',
      'd=${Uri.encodeQueryComponent(deviceId)}',
      'n=${Uri.encodeQueryComponent(deviceName)}',
    ];
    return 'settleup://sync?${parts.join('&')}';
  }

  static ConnectLink? tryParse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'settleup' || uri.host != 'sync') {
      return null;
    }
    final q = uri.queryParametersAll;
    if (q['v']?.first != '1') return null;
    final hosts = q['h'] ?? const [];
    final d = q['d']?.first;
    if (hosts.isEmpty || d == null) return null;
    return ConnectLink(
      hosts: hosts,
      deviceId: d,
      deviceName: q['n']?.first ?? '',
    );
  }
}
```

### 5.13 SyncEngine API

FILE: `lib/sync/sync_engine.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.13). Owner: sync-core.
// The only sync API the UI uses.
import 'package:meta/meta.dart';

import '../core/ids.dart';
import '../core/models.dart';
import 'transport/transport.dart';

enum SyncPhase { connecting, handshaking, comparing, transferring, finishing }

enum SyncFailure {
  permissionDenied,
  radioOff,
  peerUnreachable,
  timeout,
  noSharedGroups,
  authFailed,
  protocolMismatch,
  connectionLost,
  invalidCode, // QR/link could not be parsed
  cancelled,
  internal,
}

final class SyncException implements Exception {
  const SyncException(this.failure, [this.message = '', this.partial]);
  final SyncFailure failure;
  final String message;
  final SyncSummary? partial;
  @override
  String toString() => 'SyncException(${failure.name}: $message)';
}

@immutable
final class SyncProgress {
  const SyncProgress({
    required this.peerName,
    required this.transport,
    required this.phase,
    this.peerDeviceId,
    this.groupIds = const [],
    this.sentOps = 0,
    this.toSendOps = 0,
    this.receivedOps = 0,
    this.toReceiveOps = 0,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.verificationCode,
  });

  final String peerName;
  final DeviceId? peerDeviceId;
  final TransportKind transport;
  final SyncPhase phase;
  final List<GroupId> groupIds; // shared groups in this session
  final int sentOps;
  final int toSendOps;
  final int receivedOps;
  final int toReceiveOps; // from the peer's OPS.total; 0 until known
  final int bytesSent;
  final int bytesReceived;

  /// 6 digits derived from the handshake transcript; identical on both
  /// phones ("Check that Priya's phone shows 482 913"). Null before auth.
  final String? verificationCode;
}

@immutable
final class SyncSummary {
  const SyncSummary({
    required this.peerName,
    required this.transport,
    required this.startedAt,
    required this.endedAt,
    required this.sentOps,
    required this.receivedOps,
    required this.receivedByGroup,
    required this.groupIds,
    this.peerDeviceId,
  });

  final String peerName;
  final DeviceId? peerDeviceId;
  final TransportKind transport;
  final DateTime startedAt;
  final DateTime endedAt;
  final int sentOps;
  final int receivedOps;
  final Map<GroupId, int> receivedByGroup;
  final List<GroupId> groupIds;
}

sealed class SessionStatus {
  const SessionStatus();
}

final class SessionIdle extends SessionStatus {
  const SessionIdle();
}

final class SessionActive extends SessionStatus {
  const SessionActive(this.progress);
  final SyncProgress progress;
}

final class SessionCompleted extends SessionStatus {
  const SessionCompleted(this.summary);
  final SyncSummary summary;
}

final class SessionFailed extends SessionStatus {
  const SessionFailed(this.failure, this.message, [this.partial]);
  final SyncFailure failure;
  final String message;
  final SyncSummary? partial;
}

/// "Visible" mode details for the host screen.
@immutable
final class HostInfo {
  const HostInfo({
    required this.connectLink,
    required this.addresses,
    required this.expiresAt,
    required this.transports,
    this.wifiName,
  });

  final String connectLink; // settleup://sync?... (SPEC 8.6), shown as QR
  final List<String> addresses; // 'ip:port' on every usable interface
  final DateTime expiresAt; // auto-stop (default 5 min)
  final Set<TransportKind> transports; // actually advertising
  final String? wifiName; // SSID if known (needs location on some APIs)
}

@immutable
final class SyncStatus {
  const SyncStatus({
    this.host,
    this.discovering = false,
    this.session = const SessionIdle(),
  });

  final HostInfo? host; // non-null while visible
  final bool discovering;
  final SessionStatus session;

  static const SyncStatus idle = SyncStatus();
}

/// A phone seen nearby, merged across transports by device id.
@immutable
final class NearbyPeer {
  const NearbyPeer({
    required this.key,
    required this.name,
    required this.transports,
    required this.sharedGroupIds,
    this.deviceIdPrefix,
  });

  final String key; // stable for the discovery run
  final String name;
  final String? deviceIdPrefix;
  final Set<TransportKind> transports; // preferred: lan > nearby > ble
  final List<GroupId> sharedGroupIds; // from tokens; empty = unknown/none

  bool get sharesGroups => sharedGroupIds.isNotEmpty;
}

@immutable
final class JoinResult {
  const JoinResult({
    required this.groupId,
    required this.groupName,
    required this.alreadyMember,
    this.firstSync,
  });

  final GroupId groupId;
  final String groupName;
  final bool alreadyMember;
  final SyncSummary? firstSync; // when the invite carried a reachable host
}

abstract interface class SyncEngine {
  SyncStatus get status;
  Stream<SyncStatus> watchStatus(); // emits current first

  /// Emits the current list first; updated as peers appear/disappear
  /// (a peer not seen for 15 s is dropped).
  Stream<List<NearbyPeer>> watchNearby();

  Future<Map<TransportKind, TransportAvailability>> availability();
  Future<Map<TransportKind, TransportAvailability>> requestPermissions(
      Set<TransportKind> kinds);

  /// Starts the LAN server (+ mDNS) and Bluetooth advertising; accepts and
  /// runs inbound sessions automatically until stopped or expired.
  Future<HostInfo> startHosting({Duration duration = const Duration(minutes: 5)});
  Future<void> stopHosting();

  Future<void> startDiscovery({
    Set<TransportKind> kinds = const {TransportKind.lan, TransportKind.nearby, TransportKind.ble},
  });
  Future<void> stopDiscovery();

  /// Runs one full session (all shared groups) over the best transport.
  /// Throws [SyncException]. Status is updated throughout.
  Future<SyncSummary> syncWith(NearbyPeer peer);

  /// Accepts a scanned/pasted `settleup://sync?...` link (or a join link
  /// that carries a host). Throws [SyncException].
  Future<SyncSummary> syncWithLink(String link);

  /// Accepts a `settleup://join?...` invite: stores the group key, then
  /// syncs immediately if the invite has a reachable host. Throws
  /// [SyncException] (invalidCode) for bad links; a failed first sync is
  /// reported in the result (firstSync null), not thrown.
  Future<JoinResult> acceptInvite(String link);

  /// Builds the invite link for [groupId] (SPEC 8.6). With [includeHost],
  /// hosting is started (if not already) and its address is embedded.
  Future<String> inviteLinkFor(GroupId groupId, {bool includeHost = true});

  /// Cancels the running session (status -> SessionFailed(cancelled)).
  Future<void> cancel();

  /// Keeps an authenticated session open and pushes new local ops while
  /// the Sync screen is visible. Off by default.
  set liveMode(bool enabled);

  Stream<List<SyncRecord>> watchHistory();

  Future<void> dispose();
}
```

### 5.14 Providers the UI consumes

FILE: `lib/ui/providers.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.14). Owner: ui.
// Riverpod 3, no codegen. Root providers are overridden in lib/bootstrap.dart
// (real app) or in tests (fakes). Screens may add private providers in their
// own files but must not change these.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/activity.dart';
import '../core/balances.dart';
import '../core/ids.dart';
import '../core/ledger_state.dart';
import '../core/models.dart';
import '../data/repositories.dart';
import '../sync/sync_engine.dart';

// ------------------------------------------------------------------ roots --

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => throw UnimplementedError('Override in bootstrap()'),
);

final ledgerRepositoryProvider = Provider<LedgerRepository>(
  (ref) => throw UnimplementedError('Override in bootstrap()'),
);

final syncEngineProvider = Provider<SyncEngine>(
  (ref) => throw UnimplementedError('Override in bootstrap()'),
);

// ---------------------------------------------------------------- streams --

final profileProvider = StreamProvider<Profile?>(
  (ref) => ref.watch(settingsRepositoryProvider).watchProfile(),
);

final appSettingsProvider = StreamProvider<AppSettings>(
  (ref) => ref.watch(settingsRepositoryProvider).watchSettings(),
);

final deviceIdentityProvider = StreamProvider<DeviceIdentity>(
  (ref) => ref.watch(settingsRepositoryProvider).watchDevice(),
);

final ledgerProvider = StreamProvider<LedgerSnapshot>(
  (ref) => ref.watch(ledgerRepositoryProvider).watch(),
);

final syncStatusProvider = StreamProvider<SyncStatus>(
  (ref) => ref.watch(syncEngineProvider).watchStatus(),
);

final nearbyPeersProvider = StreamProvider<List<NearbyPeer>>(
  (ref) => ref.watch(syncEngineProvider).watchNearby(),
);

final syncHistoryProvider = StreamProvider<List<SyncRecord>>(
  (ref) => ref.watch(syncEngineProvider).watchHistory(),
);

// ---------------------------------------------------------------- derived --
// Pure functions of (snapshot, me). AsyncLoading until both are available.

AsyncValue<R> _withMe<R>(
  Ref ref,
  R Function(LedgerSnapshot snap, PersonId me) build,
) {
  final snap = ref.watch(ledgerProvider);
  final profile = ref.watch(profileProvider);
  if (snap case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  if (profile case AsyncError(:final error, :final stackTrace)) {
    return AsyncError(error, stackTrace);
  }
  final s = snap.value;
  final p = profile.value;
  if (s == null || p == null) return const AsyncLoading();
  return AsyncData(build(s, p.personId));
}

final groupSummariesProvider =
    Provider<AsyncValue<List<GroupBalanceSummary>>>(
  (ref) => _withMe(ref, (s, me) => Summaries.groups(s.state, me)),
);

final peopleBalancesProvider = Provider<AsyncValue<List<PersonBalance>>>(
  (ref) => _withMe(ref, (s, me) => Summaries.people(s.state, me)),
);

final overallBalanceProvider = Provider<AsyncValue<OverallBalance>>(
  (ref) => _withMe(ref, (s, me) => Summaries.overall(s.state, me)),
);

final groupProvider = Provider.family<AsyncValue<GroupState?>, GroupId>(
  (ref, groupId) =>
      ref.watch(ledgerProvider).whenData((s) => s.state.groups[groupId]),
);

final groupTransfersProvider =
    Provider.family<AsyncValue<List<Transfer>>, GroupId>(
  (ref, groupId) => ref.watch(ledgerProvider).whenData((s) {
    final g = s.state.groups[groupId];
    return g == null ? const <Transfer>[] : BalanceCalculator.suggestedTransfers(g);
  }),
);

final groupNetsProvider = Provider.family<AsyncValue<NetsByCurrency>, GroupId>(
  (ref, groupId) => ref.watch(ledgerProvider).whenData((s) {
    final g = s.state.groups[groupId];
    return g == null ? const <String, Map<MemberId, int>>{} : BalanceCalculator.groupNets(g);
  }),
);

/// null = all groups.
final activityProvider =
    Provider.family<AsyncValue<List<ActivityEntry>>, GroupId?>(
  (ref, groupId) => ref.watch(ledgerProvider).whenData(
        (s) => ActivityBuilder.build(
          ops: s.ops,
          state: s.state,
          localDeviceId: s.localDeviceId,
          unsharedOpIds: s.unsharedOpIds,
          groupId: groupId,
        ),
      ),
);

final expenseHistoryProvider =
    Provider.family<AsyncValue<List<ActivityEntry>>, ExpenseId>(
  (ref, expenseId) => ref.watch(ledgerProvider).whenData(
        (s) => ActivityBuilder.historyOf(
          ops: s.ops,
          state: s.state,
          localDeviceId: s.localDeviceId,
          unsharedOpIds: s.unsharedOpIds,
          entityId: expenseId,
        ),
      ),
);
```

### 5.15 Design-system widget constructors

FILE: `lib/ui/widgets/widgets.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.15). Owner: ui-kit.
// Public constructors of the design-system widgets (DESIGN.md section 5).
// ui-kit implements the build() methods (one file per widget, exported
// from this barrel); ui-screens only uses these constructors.
import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../core/models.dart';

/// Level vial (DESIGN 5.1). position in -1..1 (owe .. owed), already eased
/// by the caller via LevelVial.positionFor().
class LevelVial extends StatelessWidget {
  const LevelVial({
    super.key,
    required this.position,
    this.height = 16,
    this.showEndLabels = true,
    this.settled = false,
    this.animate = true,
  });

  final double position;
  final double height;
  final bool showEndLabels;
  final bool settled; // thick center marks + owedContainer fill
  final bool animate; // spring to new position (respects reduced motion)

  /// x = (owedToMe - iOwe) / max(owedToMe + iOwe, 1), clamped, sign*sqrt.
  static double positionFor({required int owedToMe, required int iOwe}) =>
      throw UnimplementedError();

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Overall/group balance hero (DESIGN 5.1).
class BalanceHero extends StatelessWidget {
  const BalanceHero({
    super.key,
    required this.net,
    required this.owedToMe,
    required this.iOwe,
    required this.mainCurrency,
    this.onTap,
  });

  final Map<String, int> net; // currency -> minor
  final Map<String, int> owedToMe;
  final Map<String, int> iOwe;
  final String mainCurrency; // drives the vial
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

enum BalanceRowKind { person, group, member }

/// Person / group / group-member row with signed amount + direction word
/// (DESIGN 5.2). Uses the largest-|amount| currency, "+N more" for others.
class BalanceRow extends StatelessWidget {
  const BalanceRow({
    super.key,
    required this.kind,
    required this.id, // personId / groupId / memberId (avatar tone seed)
    required this.title,
    required this.subtitle,
    required this.net,
    this.emoji,
    this.isPlaceholder = false,
    this.onTap,
    this.onLongPress,
  });

  final BalanceRowKind kind;
  final String id;
  final String title;
  final String subtitle;
  final Map<String, int> net; // + = owes you / you're owed / gets back
  final String? emoji;
  final bool isPlaceholder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Expense or payment row (DESIGN 5.3).
class ExpenseRow extends StatelessWidget {
  const ExpenseRow({
    super.key,
    required this.expense,
    required this.memberNames, // MemberId -> display name ("You" for me)
    required this.myMemberId,
    this.unshared = false,
    this.deleted = false,
    this.onTap,
    this.onRestore,
  });

  final Expense expense;
  final Map<MemberId, String> memberNames;
  final MemberId? myMemberId;
  final bool unshared;
  final bool deleted;
  final VoidCallback? onTap;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Custom numeric keypad with live display (DESIGN 5.4).
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({
    super.key,
    required this.currency,
    required this.valueMinor,
    required this.onChanged,
    this.onCurrencyTap,
    this.showDisplay = true,
  });

  final String currency;
  final int valueMinor;
  final ValueChanged<int> onChanged; // capped at Money.maxMinor
  final VoidCallback? onCurrencyTap;
  final bool showDisplay;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Equally / Amounts / Percent / Shares segmented control (DESIGN 5.5).
/// Adjustment is reachable from the split editor's overflow, not a segment.
class SplitMethodSelector extends StatelessWidget {
  const SplitMethodSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SplitMethod value;
  final ValueChanged<SplitMethod> onChanged;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Remainder bar + sentence under the split selector (DESIGN 5.5).
class RemainderBar extends StatelessWidget {
  const RemainderBar({
    super.key,
    required this.method,
    required this.targetUnits,
    required this.assignedUnits,
    required this.currency,
  });

  final SplitMethod method; // percent -> units are basis points
  final int targetUnits;
  final int assignedUnits;
  final String currency;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Initials avatar with stable tone (DESIGN 5.6). Sizes 24/32/40/56.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 40,
    this.isPlaceholder = false,
  });

  final String id;
  final String name;
  final double size;
  final bool isPlaceholder; // dashed ring

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Category glyph disc (DESIGN 5.3); maps Categories ids to icons.
class CategoryGlyph extends StatelessWidget {
  const CategoryGlyph({super.key, required this.categoryId, this.size = 40});

  final String categoryId;
  final double size;

  static IconData iconFor(String categoryId) => throw UnimplementedError();

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Empty state with static vial (DESIGN 5.7).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.headline,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String headline;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

enum SyncChipState { neverSynced, allShared, changesWaiting, inProgress, failed }

/// App-bar sync chip (DESIGN 5.8). Never says "offline".
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({
    super.key,
    required this.state,
    this.pendingCount = 0,
    this.lastSyncedAt,
    this.peerName,
    this.onTap,
  });

  final SyncChipState state;
  final int pendingCount;
  final DateTime? lastSyncedAt;
  final String? peerName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Signed, formatted, tabular amount + optional direction word.
class MoneyText extends StatelessWidget {
  const MoneyText({
    super.key,
    required this.minor,
    required this.currency,
    this.style = MoneyTextStyle.row,
    this.signed = true,
    this.colored = true,
  });

  final int minor;
  final String currency;
  final MoneyTextStyle style;
  final bool signed;
  final bool colored;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

enum MoneyTextStyle { hero, row, keypad, inline }
```

WP-E puts each widget in its own file under `lib/ui/widgets/` and turns `widgets.dart` into a barrel that `export`s them, keeping these exact constructors. Until then, WP-F compiles against the stubs.

### 5.15.1 Money formatting

FILE: `lib/ui/format/money_format.dart`

```dart
// FROZEN CONTRACT (docs/SPEC.md section 5.15). Owner: ui-kit.
import 'package:intl/intl.dart';

import '../../core/money.dart';

abstract final class MoneyFormat {
  static const String minusSign = '−'; // real minus, never '-'

  /// "£12.00", "¥500", "−£8.40" (signed: true adds '+' for positives).
  /// Uses intl NumberFormat.currency with the currency's minorDigits and
  /// Currencies symbol; [locale] null = Intl.defaultLocale.
  static String format(int minor, String currency,
      {bool signed = false, String? locale}) {
    final c = Currencies.of(currency);
    final f = NumberFormat.currency(
      locale: locale,
      name: c.code,
      symbol: c.symbol,
      decimalDigits: c.minorDigits,
    );
    final body = f.format(minor.abs() / c.minorPerMajor);
    if (minor < 0) return '$minusSign$body';
    if (signed && minor > 0) return '+$body';
    return body;
  }

  /// Screen-reader text: "12 pounds 50" style is out of scope for MVP;
  /// returns "12.50 GBP" with words supplied by the caller.
  static String spoken(int minor, String currency) {
    final c = Currencies.of(currency);
    final major = minor.abs() ~/ c.minorPerMajor;
    final rest = minor.abs() % c.minorPerMajor;
    final frac = c.minorDigits == 0
        ? ''
        : '.${rest.toString().padLeft(c.minorDigits, '0')}';
    return '$major$frac ${c.code}';
  }
}
```

### 5.16 Contract notes

- `LedgerSnapshot.ops` is the full op list sorted ascending by `hlc` (encoded string order equals `Hlc.compareTo`). It is shared, unmodifiable, and rebuilt only when ops change.
- `watch()`, `watchProfile()`, `watchSettings()`, `watchDevice()`, `watchStatus()`, `watchNearby()`, `watchHistory()` and `watchSyncRecords()` **emit the current value immediately on listen** (use a `StreamController.broadcast` plus an `async*` wrapper that yields the current value first). Providers rely on this.
- Ledger commands are serialized through a single async queue, so the counter and HLC never race.
- Limits enforced by `Ledger` (throw `LedgerException(invalidInput)`): group name 1..60 characters, member display name 1..40, description 1..120, notes ≤ 1000, ≤ 50 active members per group, total 1..`Money.maxMinor`. Text is trimmed. These keep one op well under 8 KiB, so any op fits a BLE frame.
- Category ids, enum `.name` strings and field names are wire format. Renaming any of them is a protocol change (bump `kSchemaVersion`).

---

## 6. Algorithms

All functions are deterministic: same inputs give the same output on every device, independent of map iteration order. Whenever an order is needed, sort member ids with `String.compareTo`. All amounts are `int` minor units. Totals are always > 0 (refunds are entered as an expense paid by the person who received the refund).

### 6.1 Splits (`SplitCalculator`)

**`allocate(total, weights)`** (largest remainder, the base of everything):

```text
W = Σ weights (weights ≥ 0); if W == 0 → SplitException(zeroWeight)
for each member i: base_i = (total * w_i) ~/ W ; rem_i = (total * w_i) % W
leftover = total − Σ base_i                     // 0 ≤ leftover < number of members with w_i > 0
sort members by rem_i DESC, then member id ASC
the first `leftover` members get base_i + 1
drop zero entries
```

Overflow is impossible: total ≤ 999,999,999 and weights ≤ 10,000 (percent) or ≤ 1,000 (shares) keep products below 2^53.

| Method | `values` meaning | Validation (`SplitError`) | Computation |
|---|---|---|---|
| `equal` | `{member: 1}` for each participant | `noParticipants` if empty | `allocate(total, all 1)`. With equal remainders, ties go to the lowest member ids, which matches DESIGN 5.5 ("Sam pays 1p more"). |
| `exact` | `{member: minor}`, each ≥ 0 | `sumMismatch` if Σ ≠ total; `negativeShare` if any < 0; `noParticipants` if all 0 | values as given, zeros dropped |
| `percent` | `{member: basis points}` (12.5% = 1250), each 0..10000 | `percentNot100` if Σ ≠ 10000 | `allocate(total, bp)` |
| `shares` | `{member: weight}`, each 1..1000 (integers; "0.5 share" is not supported) | `zeroWeight` if any < 1 or empty | `allocate(total, weights)` |
| `adjustment` | `{member: signed minor}`, 0 = no adjustment; keys = all participants | `negativeShare` if `rest = total − Σadj < 0` or any final share < 0 | `base = allocate(rest, all 1)`; `share_i = base_i + adj_i` |

Every method then asserts Σ shares == total (a failed assertion is a bug, not a user error). `nonPositiveTotal` is raised for total ≤ 0 or > `Money.maxMinor`.

`check(total, spec)` (never throws) feeds the remainder bar: `exact` → target = total, assigned = Σ values; `percent` → target = 10000, assigned = Σ bp; `adjustment` → target = total, assigned = Σ adj; `equal`/`shares` → target = assigned = Σ weights. `shares` is filled with the computed amounts when valid.

**Payer side:** `paidBy` is also a `SplitSpec` and accepts `equal`, `exact`, `percent`, `shares`. The UI exposes "Paid by you" (single exact), "Multiple people" with exact amounts, and "Split equally among payers". `buildMoneyBlock` = `paid = compute(total, paidBy)`, `owed = compute(total, owedBy)`. Payments: `paymentBlock(from, to, amount)` = `paidBy = single(from, amount)`, `owedBy = single(to, amount)`.

**Test vectors (must be in `test/core/split_test.dart`):** ids are `a` < `b` < `c`.

| total | spec | expected |
|---|---|---|
| 1000 | equal a,b,c | a 334, b 333, c 333 |
| 100 | equal c,a,b (insertion order shuffled) | a 34, b 33, c 33 |
| 1000 | percent a 3333, b 3333, c 3334 | a 333, b 333, c 334 |
| 1000 | shares a 2, b 1 | a 667, b 333 |
| 6000 | adjustment a +1000, b 0, c 0 | a 2667, b 1667, c 1666 |
| 6000 | exact a 2000, b 2000, c 1550 | `sumMismatch`; check: remaining 450 |
| 6000 | exact a 2000, b 2000, c 2500 | `sumMismatch`; check: remaining −500 |
| 1 | equal a,b,c | a 1 |
| 500 (JPY) | equal a,b,c | a 167, b 167, c 166 |
| 6000 | adjustment a −7000, b 0 | `negativeShare` |

### 6.2 Group nets

```text
for e in group.liveExpenses (expenses AND payments; deleted and inconsistent excluded):
  for (m, v) in e.money.paid: nets[e.currency][resolve(m)] += v
  for (m, v) in e.money.owed: nets[e.currency][resolve(m)] -= v
drop zero entries and empty currencies
```

`resolve` follows `mergedInto` (6.7). Removed members keep their balances. Invariant: each currency sums to 0.

### 6.3 Pairwise ("original") debts

For each live expense and each ower `o` (resolved) with owed amount `w`: split `w` across the payers in proportion to what they paid, using `allocate(w, paidResolved)` (merged payers are summed first). Add a debt `o → p` for each payer `p ≠ o`. Then net each unordered pair per currency (A→B 30 and B→A 10 become A→B 20) and drop zeros. Output is sorted by currency, from, to.

Vector: E1 total 9000, paid a 9000, owed equal a,b,c (3000 each); E2 total 3000, paid b 3000, owed a 1500, b 1500 → `[b→a 1500, c→a 3000]`.

### 6.4 Simplify debts (`DebtSimplifier.simplify`), per currency

Greedy min cash flow with two max-heaps (`HeapPriorityQueue` from `package:collection`):

```text
creditors: heap of (amount > 0, id), ordered amount DESC, then id ASC
debtors:   heap of (|amount| for amount < 0, id), same ordering
while creditors and debtors are non-empty:
  c = creditors.removeFirst(); d = debtors.removeFirst()
  x = min(c.amount, d.amount)
  emit Transfer(from: d.id, to: c.id, amount: x)
  if c.amount − x > 0: creditors.add((c.amount − x, c.id))
  if d.amount − x > 0: debtors.add((d.amount − x, d.id))
```

Output is in emission order. It produces at most n − 1 transfers and never changes anyone's net. Throw `ArgumentError` if the nets do not sum to 0. `BalanceCalculator.suggestedTransfers(g)` = for each currency in ascending code order: `g.group!.simplifyDebts ? simplify(nets[cur], cur) : pairwise transfers of that currency`. It is a view only and is never stored.

Vectors: `{a:+50, b:−30, c:−20}` → `[b→a 30, c→a 20]`; chain `{A:−10, B:0, C:+10}` → `[A→C 10]`; ties `{a:+10, b:+10, c:−10, d:−10}` → `[c→a 10, d→b 10]`; `{}` → `[]`.

(The exact bitmask DP for groups of 12 or fewer is a v1.1 option. It is not in the MVP.)

### 6.5 People and overall (`Summaries`)

- `me` in a group = `memberForPerson(profile.personId)`, resolved. A group without my member contributes nothing to my balances.
- `people(state, me)`: for every visible group (direct groups included) where I have a member, take `suggestedTransfers(g)`. For each transfer to my member, add `+amount` to the person of `t.from`. For each transfer from my member, add `−amount` to the person of `t.to`. The person key is the resolved member's `personId`. Every other active member of my groups also gets an entry (possibly settled), so the Friends tab lists them. `displayName` = the name of that person's most recently created member.
- `overall(state, me)`: `owedToMe[cur]` = Σ positive person nets, `iOwe[cur]` = Σ |negative person nets|, `net = owedToMe − iOwe`. This equals Σ of my group nets, because the suggested transfers settle my net exactly. Assert it in tests.
- `groups(state, me)`: non-direct visible groups, `myNet` from `groupNets`, unsettled first, then `lastActivityAt` descending.

### 6.6 Multi-currency rule (MVP)

Every expense carries its own currency, and balances are computed and shown **per currency** with no conversion. Splitting, simplification and settlement suggestions run separately per currency. A payment is in one currency and settles only that currency. The UI shows the largest-magnitude currency first and "+N more" for the rest (DESIGN 5.1, 5.2). The hero vial uses the profile's home currency. If that currency has no balance, it uses the largest one.

### 6.7 Member merge and removal

- `resolve(id)`: follow `mergedInto` until a member with no `mergedInto` is reached, or until a member is revisited (cycle). On a cycle, return the smallest id in the cycle. A missing target member returns the last id reached.
- Removal is a tombstone (`deletedAt`). The UI blocks "Remove" when the member's net is non-zero in any currency. The repository does not block it, because a concurrent offline expense can still involve the member, and that is valid.

---

## 7. Op log and merge semantics

### 7.1 Creating ops (Ledger)

- `counter` = 1 + `maxCounter(groupId, myDeviceId)` (cached in memory), strictly contiguous per (device, group).
- `hlc` = `clock.tick()`. One command may produce several ops (create group = 1 group op + N member ops). Each op gets its own tick and counter, and all are inserted in one `insertAll` call.
- `create` payloads carry **every** required field (`*Fields.required`) plus optional ones. `update` payloads carry only changed fields. `delete` = `{deletedAt: hlc.millis}`. `restore` = `{deletedAt: null}`.
- Merge members = `update` on the `from` member with `{mergedInto: into}`. Claim = `update` with `{personId: me, deviceId: myDeviceId}`.
- `kv['hlc.last']` is written after every commit.

### 7.2 Reducer rules (`LedgerReducer.apply`)

State per entity key `(entityType, entityId)`: `created: bool`, and `fields: Map<field, (Hlc hlc, Object? value)>`. Also kept: a set of applied op ids.

1. If the op id was already applied, return false. Record it.
2. If `op.isFromNewerSchema`, return false. The op is stored and relayed, but not applied.
3. For `EntityType.group`, if `entityId != groupId`, ignore the op. Member and expense entities belong to `op.groupId`. An op whose entity id already exists in another group is ignored (ids are UUIDs, so this only happens with malicious input).
4. For each `(field, value)` in the payload: if there is no current value, or `op.hlc > current.hlc`, set `(op.hlc, value)`. Equal HLCs from different ops cannot happen (the device id is inside the HLC). If they do, keep the current value.
5. If `op.kind == create`, set `created = true`.
6. Rebuild the materialized entity. It is **visible** only if `created`, every required field is present with the right JSON type, and (expenses) `MoneyBlock.fromJson` succeeds with `isConsistent == true` and currency == `money.currency`. Fields with a wrong JSON type are treated as absent. Unknown fields are kept in `fields` (forward compatibility) but ignored by the builders.
7. Invisible entities stay in the reducer's field state, so a later op can complete them. They are absent from `GroupState.members` / `.expenses`.
8. `Expense.updatedHlc` = max HLC over all applied ops of that expense. `Group.createdAt`, `Member.createdAt` and `Expense.createdAt` come from their fields.

Because every visible value is "the max-HLC write per field, over the set of ops", the result is independent of order and duplication. That is the convergence guarantee.

**`money` is one field.** Amount, currency, payers and split always travel together, so a concurrent edit can never produce shares that do not sum to the total. The losing version stays in the op log. `ActivityEntry.supersededBy` marks it, and the UI says "Priya also edited Dinner. We kept her version from 14:02. [See both]".

**Conflict table:**

| Case | Result |
|---|---|
| A edits the description, B edits the amount (offline) | Both kept (different fields). |
| A and B both edit the amount/split | Higher HLC money block wins; the other is shown in history. |
| Edit vs delete | Deleted (edits do not touch `deletedAt`); restore brings back the latest edits. |
| Delete vs later restore | Higher HLC on `deletedAt` wins. |
| Both add "Bob" | Two members; the UI offers "Merge members". |
| Expense references a removed member | Still counted; the UI shows "(removed) Bob". |
| Two payments recorded for the same debt | Both kept. The UI hints "possible duplicate" (same from, to, amount within 24 h). |
| Concurrent merges A→B and B→A | Cycle; resolves to the smaller id (6.7). |

### 7.3 HLC usage

- `HlcClock.tick()` for each local op. `HlcClock.receive(maxRemoteHlc)` once per applied remote batch.
- Skew guard: a remote HLC more than 1 hour ahead of the local wall clock is accepted as data but not adopted by the clock (`skewDetected = true`, logged). Convergence is unaffected (the order is still total), but that phone's edits may win LWW ties surprisingly. The Settings "About" line shows "This phone's clock looks wrong" when the flag is set.

### 7.4 Version vectors and gaps

`OpStore` keeps the **contiguous** max counter per (group, device). Ops beyond a gap are stored but not counted. They will be offered again by the next peer (duplicates are ignored) until the gap closes. On insert, advance with `while exists(counter = vv + 1) vv++`.

A second op with the same (group, device, counter) but a different op id means a forked device (for example a restored backup). Keep the first, ignore the second, and log it. To prevent forks, Android auto-backup is disabled (section 9.1).

### 7.5 SQLite schema (`lib/data/schema.dart`, `PRAGMA user_version = 1`)

```sql
PRAGMA journal_mode = WAL;
CREATE TABLE ops(
  op_id       TEXT PRIMARY KEY,
  group_id    TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  counter     INTEGER NOT NULL,
  hlc         TEXT NOT NULL,
  schema_ver  INTEGER NOT NULL,
  json        TEXT NOT NULL,          -- jsonEncode(op.toJson()), verbatim
  received_at INTEGER NOT NULL,       -- local bookkeeping, never synced
  UNIQUE(group_id, device_id, counter)
) STRICT;
CREATE INDEX ops_group_hlc ON ops(group_id, hlc);
CREATE TABLE vv(group_id TEXT NOT NULL, device_id TEXT NOT NULL, max_counter INTEGER NOT NULL,
  PRIMARY KEY(group_id, device_id)) STRICT;
CREATE TABLE peer_vv(peer_id TEXT NOT NULL, group_id TEXT NOT NULL, device_id TEXT NOT NULL,
  max_counter INTEGER NOT NULL, PRIMARY KEY(peer_id, group_id, device_id)) STRICT;
CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE sync_records(id TEXT PRIMARY KEY, started_at INTEGER NOT NULL, json TEXT NOT NULL) STRICT;
```

`kv` keys: `device` (JSON `{deviceId, deviceName}`), `profile` (JSON), `settings` (JSON), `hlc.last` (encoded HLC), `pending.<groupId>` (name hint for a pending join). Migrations are a `switch (user_version)` ladder in `schema.dart`.

"Unshared" ops (sync chip "3 changes to share", row dot) = my own ops with `counter > peerKnowledge(group)[myDeviceId]`.

### 7.6 Schema evolution

`kSchemaVersion = 1`. A newer app writes ops with a higher `schemaVersion`. Older apps parse them with placeholder entity type/kind, keep `Operation.raw`, store and relay them byte for byte, and never apply them. After the user updates, the reducer replays all stored ops on startup and the newer ops take effect. Unknown payload fields in v1 ops are preserved in the same way.

---

## 8. Sync

### 8.1 Layers

```text
SyncEngine (orchestration: hosting, discovery, choosing a transport, one session at a time)
  └─ SyncSession (state machine; transport agnostic; unit tested over MemoryTransport)
       ├─ crypto: handshake (X25519 + group PSKs → HKDF), AES-256-GCM per frame
       ├─ codec: message <-> plain frame (type, flags, JSON body, optional gzip)
       └─ FrameChannel (reliable ordered frames)  ← LanTransport | NearbyTransport | BleTransport | MemoryTransport
```

### 8.2 Frame format (session layer, identical on every transport)

```text
channel frame := 0x00 plain | 0x01 sealed
plain         := type:u8 | flags:u8 | body            (flags bit0 = body is gzip)
sealed        := nonce:12 | AES-256-GCM(key_dir, nonce, plain) ciphertext || tag:16
nonce         := 0x00000000 | counter:u64be             (per direction, starts at 0, +1 per frame)
body          := UTF-8 JSON object (gzip with dart:io gzip when JSON > 1024 bytes)
```

Only `HELLO`, `AUTH` and `ERROR` may be plain. Everything after both AUTHs is sealed. The receiver requires `counter == expected` (strictly sequential, since the channel is ordered), which rejects replay and reordering. A decryption failure closes the session with `authFailed`. The negotiated max frame size is `min(local.maxFrame, peer.maxFrame)`.

### 8.3 Discovery tokens and blinded group ids

- **Advertisement token** (lets a scanner see "this phone shares a group with me" without revealing group ids): `token(g, w) = hex(HMAC-SHA256(groupKey_g, utf8("settleup-adv-v1:" + w)))[0..16]`, where `w = unixSeconds ~/ 600`. Advertise tokens for the current window, and refresh them when the window changes. A scanner matches against windows `w` and `w − 1` for all of its group keys. `NearbyPeer.sharedGroupIds` = the matched groups.
- **Blinded group id in HELLO:** `blind(g, nonce) = base64url(HMAC-SHA256(groupKey_g, utf8("settleup-gid-v1") || nonce)[0..16])`, using the **sender's** HELLO nonce. A replayed HELLO fails, because the receiver recomputes the value with the replayer's own nonce.

### 8.4 Handshake (Noise-NNpsk-like, per connection)

The initiator (I) is the side that called `connect()`. The responder (R) accepted.

1. On channel open, both sides immediately send `HELLO` (plain). The HELLO frame bytes are kept for the transcript.
2. On receiving the peer's HELLO: negotiate the protocol: `proto = min(mine.proto, peer.proto)`, which must be ≥ `max(mine.minProto, peer.minProto)`, else send `ERROR proto_unsupported`. Compute `S` = groups I hold whose `blind(g, peer.nonce)` appears in `peer.groups`, sorted by group id. If `S` is empty, send `ERROR no_shared_groups` and close. Both honest sides compute the same `S`.
3. Key schedule:
   ```text
   dh   = X25519(myEphemeralPrivate, peerEphemeralPublic)          32 bytes
   ikm  = dh || groupKey(S[0]) || groupKey(S[1]) || ...
   salt = nonce_I || nonce_R                                       32 bytes
   info = utf8("settleup-sync-v1|" + S.join(","))
   okm  = HKDF-SHA256(ikm, salt, info, length: 96)
   k_IR = okm[0..32]   k_RI = okm[32..64]   k_auth = okm[64..96]
   transcript = SHA-256(helloFrame_I || helloFrame_R)
   ```
4. Each side sends `AUTH{mac}` with `mac = HMAC-SHA256(k_auth, utf8("I") || transcript)` for the initiator, or `utf8("R")` for the responder (this prevents reflection). It verifies the peer's mac in constant time. On a mismatch: `ERROR auth_failed`, close.
5. `verificationCode` = `(u32be(SHA-256(utf8("settleup-sas") || transcript)[0..4]) % 1000000)` padded to 6 digits. Both phones show it during the session. Showing it is informational in P0 and becomes the confirmation step for P1 pairing.

Properties: confidentiality and integrity from AES-GCM; forward secrecy from the ephemeral X25519; authentication because only holders of every group key in `S` can produce the AUTH mac; no group ids in clear on the wire; and replay protection from fresh nonces plus sequential frame counters. Not covered (documented): a member who leaves still holds the key (no rotation in MVP), and members can forge each other's ops (no signatures until Phase 2). Device id and device name are visible in HELLO.

### 8.5 Messages (protocol v1)

| Code | Type | Body (JSON) | Notes |
|---|---|---|---|
| 1 | `HELLO` | `{proto:1, minProto:1, deviceId, deviceName, app:"settleup/1.0.0", eph:b64url(32), nonce:b64url(16), groups:[b64url(16)...], maxFrame:int, transport:"lan"\|"nearby"\|"ble"}` | Plain. |
| 2 | `AUTH` | `{mac:b64url(32)}` | Plain. |
| 3 | `VV` | `{g:groupId, vv:{deviceId:int}}` | One per group in `S`. |
| 4 | `OPS` | `{g, batch:int, total:int, ops:[Operation.toJson()...], more:bool}` | `batch` starts at 1 per group. `total` = number of ops the sender will send for `g` in this session (for progress). Ops are sorted by (deviceId, counter) and **include third-party ops** (gossip relay). |
| 5 | `ACK` | `{g, batch, vv}` | After `applyRemote` commits. `vv` = the receiver's new contiguous VV. The sender then calls `recordPeerKnowledge`. |
| 6 | `DONE` | `{g}` | The sender has sent every op for `g` (`more:false` was sent, or there was nothing to send). |
| 7 | `PING` | `{t:ms}` | Keepalive. |
| 8 | `PONG` | `{t:ms}` | Echoes `t`. |
| 9 | `ERROR` | `{code, msg}` | Codes: `proto_unsupported`, `no_shared_groups`, `auth_failed`, `bad_frame`, `bad_op`, `too_large`, `busy`, `cancelled`, `internal`. |
| 10 | `BYE` | `{}` | Graceful close. |
| 11/12 | `BLOB_REQ`/`BLOB` | reserved (receipts, v1.1) | A receiver of an unknown type sends `ERROR bad_frame`. |
| 20-29 | reserved for pairing (P1, 8.7.3) | | |

**Batching:** add ops to a batch until the encoded JSON would exceed `0.75 × maxFrame` or 500 ops. If a sealed frame still exceeds `maxFrame`, split the batch in half and retry. A single op over `maxFrame` (impossible under the limits in 5.16) gives `ERROR too_large`. At most **4 un-ACKed batches** in flight per session.

### 8.6 Links and QR payloads (frozen in `lib/sync/pairing/links.dart`)

- **Invite:** `settleup://join?v=1&g=<groupId>&k=<base64url key, no padding>&n=<group name>&c=<currency>&f=<inviter device name>[&h=<ip:port>][&d=<inviter deviceId>]`. The QR shows full screen with a 2-minute auto-hide. The "Share invite link" action is explicit and warns "Anyone with this link can see and add to Goa trip". Accepting stores the key (`registerJoinedGroup`) and creates a pending join. If `h` is present, it syncs immediately. After the first sync that brings the group's `create` op, the UI asks "Which one are you?" (unclaimed members, or "I'm not listed", which adds and claims a member with my name).
- **Connect (host mode):** `settleup://sync?v=1&h=<ip:port>&h=...&d=<deviceId>&n=<deviceName>`, listing every usable IPv4 interface (hotspot interfaces first: `ap*`, `swlan*`, `wlan1`, `bridge*`). It carries no secrets. Authentication still needs a shared group.
- The QR is rendered with `qr_flutter`, error correction M, 220 dp, on a white quiet zone in both themes (DESIGN 6.8).

### 8.7 Session state machine (`SyncSession`)

```text
            ┌──────────── any state: ERROR recv / decrypt fail / timeout / channel closed ───► FAILED(reason)
            │
OPEN ──send HELLO──► HELLO_SENT ──recv HELLO, S≠∅, send AUTH──► AUTH_SENT ──recv valid AUTH──► AUTHENTICATED
                                     │ S=∅ → send ERROR no_shared_groups → FAILED
AUTHENTICATED ──send VV(g) for g∈S──► EXCHANGING
EXCHANGING:
  recv VV(g)      → missing = store.opsMissingFor(g, peerVV); send OPS batches (window 4); after last → send DONE(g)
  recv OPS(g,b)   → store.applyRemote(g, ops) → send ACK(g,b,vv)       (bad op → ERROR bad_op → FAILED)
  recv ACK(g,b)   → store.recordPeerKnowledge(peer, g, vv); release window
  recv DONE(g)    → peerDone[g] = true
  when ∀g∈S: myDone[g] ∧ peerDone[g] ∧ all my batches ACKed:
       liveMode ? → LIVE : send BYE → CLOSING
LIVE:  store.localOps(g∈S) → send OPS batch; recv OPS → apply + ACK; PING every 10 s; leaving the Sync screen → send BYE → CLOSING
CLOSING ──recv BYE or 2 s──► CLOSED (success; SyncRecord outcome=completed)
```

- Allowed before AUTHENTICATED: `HELLO`, `AUTH`, `ERROR` only. Anything else → `ERROR bad_frame`.
- Timeouts: open → AUTHENTICATED within **10 s**. While EXCHANGING, **20 s** with no frame received → `timeout`. Send `PING` after 5 s of not sending. LIVE: idle limit 30 s.
- Cancel: send `ERROR cancelled`, close, outcome `cancelled`.
- Failure after some ACKs is **partial** (outcome `partial`): everything committed stays, and the UI says "Nothing was lost: 2 of 5 changes arrived, the rest will come next time."
- Progress (`SyncProgress`) is emitted at most every 100 ms.

#### 8.7.1 Engine orchestration (`DefaultSyncEngine`)

- **One session at a time.** An inbound connection while a session runs gets `ERROR busy`.
- `startHosting`: compute tokens → `startAdvertising` on every transport whose availability is `ready` → collect interface addresses → `HostInfo` with a `connectLink`, expiring after `duration` (default 5 min). Inbound channels start responder sessions automatically.
- `startDiscovery`: subscribe to `discover()` on each requested ready transport, and merge into `NearbyPeer` by `deviceIdPrefix` when known, else by `(kind, address)`. Peers unseen for 15 s are dropped. Shared groups come from tokens (8.3).
- `syncWith(peer)`: try transports in the order **lan → nearby → ble** among `peer.transports`. On a connect failure, fall back to the next. Report `peerUnreachable` if all fail.
- `syncWithLink(link)`: parse `ConnectLink` (or an `InviteLink` with `h`) and try each host with a 4 s connect timeout.
- After each session: `addSyncRecord`, set the status to `SessionCompleted`/`SessionFailed`, then fire one `HapticFeedback` in the UI layer (not in the engine).

#### 8.7.2 Transports

**LAN (`LanTransport`, kind `lan`, maxFrame 1 MiB)**
- Server: `ServerSocket.bind(InternetAddress.anyIPv4, 52741)`, falling back to port 0 if busy. The actual port goes into mDNS and the QR. `tcpNoDelay = true`.
- Framing on the socket: `len:u32be | channel frame`. Reject `len > 1 MiB` or `len == 0` (close). Reassemble across reads (tests must cover split and coalesced reads).
- mDNS (`bonsoir`): type `_settleup._tcp`, service name = device name (≤ 40 chars). TXT: `v=1`, `d=<deviceId[0..8]>`, `t=<tokens comma-joined, ≤ 16>`. Discovery resolves to `host:port` (prefer IPv4, bracket IPv6).
- Gateway probe (hotspot case, mDNS is unreliable there): while `discover()` is listened to, every 5 s read `NetworkInfo().getWifiGatewayIP()`. If it is non-null and not one of our addresses, try `Socket.connect(gw, 52741, timeout: 1.5 s)`. On success close it immediately and emit `DiscoveredPeer(kind: lan, address: 'gw:52741', name: 'Phone sharing its hotspot')`. The server ignores connections that close before a frame.
- `HostInfo.addresses` from `NetworkInterface.list(type: IPv4)` without loopback; tethering interfaces first.

**Nearby Connections (`NearbyTransport`, kind `nearby`, Android only, maxFrame 32 KiB)**
- `serviceId = 'app.settleup.sync'`, `Strategy.P2P_CLUSTER`.
- Endpoint name (advertised) = `"1|<deviceId[0..8]>|<deviceName ≤ 24>|<up to 4 tokens comma-joined>"`. Parse it on `onEndpointFound`.
- Accept every connection automatically (`acceptConnection`). Authentication happens in our session layer.
- One channel frame = one BYTES payload (≤ 32 KiB).
- `availability()` returns `unsupported` on iOS.

**BLE GATT (`BleTransport`, kind `ble`, maxFrame 16 KiB)** using `bluetooth_low_energy` 6.2.1:
- Service `82101e6c-f454-4ceb-86a8-5375a3b1a414`. Characteristics:
  - `INFO` `cdc76358-cfae-4208-855b-5d0c5b179f6a` (read): UTF-8 JSON `{"v":1,"d":"<deviceId[0..8]>","n":"<deviceName>","t":[tokens ≤ 16]}`.
  - `RX` `fb7ee064-81d8-47d5-87dc-a89a5e02dbe7` (write with response): central → peripheral chunks.
  - `TX` `33453450-cada-4c25-afb0-ba2115611155` (notify): peripheral → central chunks.
- Advertising: service UUID only, plus local name `SU` (iOS allows only name and service UUIDs). The scanner filters on the service UUID, connects, reads `INFO` to build the `DiscoveredPeer` (cache by peripheral UUID for 60 s, then disconnect until the user taps Sync).
- On connect: Android central calls `requestMTU(517)`. Chunk size = `getMaximumWriteLength(type: withResponse)` (central) or `getMaximumNotifyLength(central)` (peripheral), minus 2.
- Chunk = `flags:u8 (bit0 FIRST, bit1 LAST) | seq:u8 (mod 256, per direction) | bytes`. Reassemble until LAST. A sequence gap → close the channel. `BleChunker` is pure Dart and unit tested.
- Flow control: central writes with response (OS paced). The peripheral awaits each `notifyCharacteristic` before sending the next chunk. On error, retry after 20 ms, up to 50 times.
- One active BLE connection at a time. The central is always the initiator.

**Memory (`MemoryTransport`, tests and UI dev)**: an in-process hub that pairs channels with configurable `maxFrameBytes`, optional latency, and fault injection (`dropAfterFrames`).

#### 8.7.3 P1: SAS pairing without QR

Over a Bluetooth channel with no shared groups: both sides run the handshake with `S = ∅`, `ikm = dh` only, and show `verificationCode`. When both users confirm, the inviter sends `PAIR_INVITE (20) {invite: <InviteLink string>}` sealed. The joiner treats it like a scanned invite. Out of P0.

### 8.8 Live mode

This is the same session staying in LIVE. The UI sets `liveMode = true` while the Sync screen is in the foreground, and `false` when it leaves. New local ops in shared groups are pushed within 1 s.

### 8.9 Security summary

| Threat | Mitigation |
|---|---|
| A stranger nearby injects expenses | No group key, so no valid blinded id or AUTH. Rejected. |
| Passive sniffing on hotspot/BLE | AES-256-GCM with ephemeral keys. Group ids are blinded. Tokens rotate every 10 min. |
| Replay of an old session | Fresh nonces in HELLO; strictly sequential frame counters. |
| QR photographed by someone | The QR is the membership secret. It auto-hides after 2 min and sharing is explicit with a warning. Rotation is Phase 2. |
| Member forges another member's op | Accepted risk for MVP (friends). Phase 2 adds Ed25519 signatures. |
| Malformed or hostile ops | `Operation.fromJson` + `SyncStore.applyRemote` validation; the reducer ignores invisible or inconsistent entities; size limits. |

### 8.10 Permissions wrapper (`lib/sync/platform/permissions.dart`, WP-D1, used by D2)

```dart
class NearbyPermissions {
  Future<TransportAvailability> check(TransportKind kind);
  Future<TransportAvailability> request(TransportKind kind); // shows the system dialog(s)
}
```

Per kind on Android (API level → permissions): `lan`: none (targetSdk 36). `nearby`: API ≥ 31 `bluetoothScan`, `bluetoothAdvertise`, `bluetoothConnect`; API ≥ 33 also `nearbyWifiDevices`; API ≤ 32 `locationWhenInUse`. `ble`: API ≥ 31 `bluetoothScan`, `bluetoothAdvertise`, `bluetoothConnect`; API ≤ 30 `locationWhenInUse`. On iOS: `ble` → `bluetooth`; `lan` → no runtime API (the system prompts on the first local-network access; a timeout there maps to `permissionDenied` with the hint "Allow Local Network for Settle Up in Settings"). `radioOff` comes from `CentralManager().state` (BLE) and the Wi-Fi state (LAN: no IPv4 interface).

---

## 9. Platform configuration (WP-D1)

### 9.1 Android

`android/app/build.gradle.kts`:

```kotlin
android {
    namespace = "app.settleup.settle_up"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.settleup.settle_up"   // codename; final store id chosen before release
        minSdk = 26          // LocalOnlyHotspot (P1); bluetooth_low_energy needs 24
        targetSdk = 36       // NOT 37: Android 17 local-network permission (ACCESS_LOCAL_NETWORK) is unverified
    }
}
```

`AndroidManifest.xml` (inside `<manifest>`):

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.CAMERA" />
<!-- Bluetooth, API 31+ ("Nearby devices" group) -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"
    tools:targetApi="s" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<!-- Wi-Fi nearby (Nearby Connections, LocalOnlyHotspot), API 33+ -->
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation"
    tools:targetApi="tiramisu" />
<!-- Legacy Bluetooth, API <= 30 -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<!-- Location: BLE scan on <= 30, Nearby Connections and LocalOnlyHotspot on <= 32 -->
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="32" />
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
<!-- Add ONLY when targetSdk >= 37, and request it with the Nearby devices group:
<uses-permission android:name="android.permission.ACCESS_LOCAL_NETWORK" /> -->
```

Add `xmlns:tools="http://schemas.android.com/tools"` on `<manifest>`. The `nearby_connections` plugin manifest declares `BLUETOOTH`, `BLUETOOTH_ADMIN` and `ACCESS_COARSE_LOCATION` without `maxSdkVersion`, so put `tools:node="replace"` on our capped declarations (`BLUETOOTH`, `BLUETOOTH_ADMIN`, both location permissions) to keep the caps after manifest merge. **Verify on a real API 31/32 device and an API 34+ device:** the plugin README (Google's page was unreachable from the sandbox) lists `BLUETOOTH_SCAN` without `neverForLocation` and `ACCESS_FINE_LOCATION` for API 29 to 31. We keep `neverForLocation` so BLE scanning works on API 33+ without location, and request location on API ≤ 32 (8.10). If Nearby discovery returns nothing on API 31+, remove the flag and request `locationWhenInUse` on every API level for `nearby` and `ble` (and lift the location `maxSdkVersion`). Record the result in `docs/QA.md`. On `<application>`: `android:allowBackup="false"` and `android:fullBackupContent="false"` (a restored op log with a cloned device id would fork counters, see 7.4). Add a `<intent-filter>` for the `settleup` scheme (hosts `join`, `sync`) on the main activity, so invite links open the app. `nearby_connections` 4.3.0 pins AGP 7.4.2 in its own buildscript. If the Gradle build rejects it, WP-D2 reports it, and the integrator vendors the plugin under `third_party/nearby_connections` with an updated build file (do not fork the Dart API).

### 9.2 iOS

`ios/Podfile`: `platform :ios, '15.0'`. `Info.plist`:

| Key | Value |
|---|---|
| `NSLocalNetworkUsageDescription` | "Settle Up finds your friends' phones on the same Wi-Fi or hotspot to share expenses." |
| `NSBonjourServices` | `["_settleup._tcp"]` |
| `NSBluetoothAlwaysUsageDescription` | "Settle Up uses Bluetooth to share expenses with friends' phones nearby, without internet." |
| `NSBluetoothPeripheralUsageDescription` | same text (legacy key) |
| `NSCameraUsageDescription` | "Settle Up uses the camera to scan a friend's QR code." |
| `CFBundleURLTypes` | scheme `settleup` |
| `UIBackgroundModes` | **not set** (foreground sync only in MVP) |

iOS has no Nearby Connections (BLE and LAN only) and cannot create a hotspot from the app (the host screen tells the user to turn on Personal Hotspot; the gateway is usually `172.20.10.1`, but it is always read at runtime).

---

## 10. UI build notes (WP-E, WP-F)

DESIGN.md is the visual source of truth. Copy `lib/theme/tokens.dart` and `lib/theme/app_theme.dart` verbatim from DESIGN 8.1 and 8.2 (replace `google_fonts` `^8.2.1` guidance with `^9.0.0`). Bundle the Atkinson Hyperlegible Next static TTFs (Regular, SemiBold, Bold, ExtraBold) plus `OFL.txt` under `assets/google_fonts/` with the file names `google_fonts` expects (`AtkinsonHyperlegibleNext-Regular.ttf` and so on). If the files cannot be downloaded in the build sandbox, ship without them; `google_fonts` falls back to the platform font. Record that in the README, but never enable runtime fetching.

### 10.1 Routes (`lib/ui/router.dart`)

| Path | Screen (DESIGN ref) | Main providers / calls |
|---|---|---|
| `/onboarding` | Onboarding (6.1); redirect target whenever `profileProvider` is `null` | `SettingsRepository.completeOnboarding` |
| `/home` (shell tab 0) | Home: hero + Groups/Friends (6.2) | `overallBalanceProvider`, `groupSummariesProvider`, `peopleBalancesProvider`, `syncStatusProvider`, `ledgerProvider.totalUnshared` |
| `/activity` (tab 1) | Activity feed (6.7), filter chips, search icon → `/search` | `activityProvider(null)`, `syncHistoryProvider` |
| `/sync` (tab 2) | Sync (6.8) | `syncStatusProvider`, `syncHistoryProvider`, `SyncEngine.availability` |
| `/sync/host` | Host mode: QR, addresses, countdown | `SyncEngine.startHosting/stopHosting` |
| `/sync/scan` | QR scanner (`mobile_scanner`) → join or connect | `acceptInvite` / `syncWithLink` |
| `/sync/session` | Progress / done / failed | `syncStatusProvider` |
| (sheet) | Nearby devices (5.9) | `nearbyPeersProvider`, `startDiscovery`, `syncWith` |
| `/groups/new`, `/groups/:gid/edit` | Create/edit group (members, currency, type, emoji, simplify) | `createGroup`, `updateGroup` |
| `/groups/:gid` | Group detail: Expenses / Balances tabs (6.3) | `groupProvider`, `groupNetsProvider`, `groupTransfersProvider` |
| `/groups/:gid/members` | Members: add, rename, merge, remove, "This is me", invite QR | member commands, `inviteLinkFor` |
| `/groups/:gid/invite` | Full-screen invite QR, 2 min auto-hide | `inviteLinkFor(includeHost: true)` |
| `/groups/:gid/claim` | "Which one are you?" after joining | `claimMember`, `addMember` |
| `/expense/new?gid=&pid=` | Add expense (6.4), with the split editor sheet (6.5) | `addExpense`, `directGroupWith` (when started from a person) |
| `/expense/:eid` | Expense detail + history | `expenseHistoryProvider`, `deleteExpense`, `restoreExpense` |
| `/expense/:eid/edit` | Edit expense | `updateExpense` / `updatePayment` |
| `/settle?gid=&from=&to=` | Settle up (6.6) with the bubble moment | `groupTransfersProvider`, `recordPayment` |
| `/people/:pid` | Person: balance per group, settle per group | `peopleBalancesProvider` |
| `/search` | Local search | `ledgerProvider` (filter in memory) |
| `/settings` | Settings (6.9): name, home currency, theme, vibration, phone name, export CSV | `SettingsRepository`, `CsvExport.group` + `share_plus` |
| `/join?...` | Deep-link handler for `settleup://join` | `acceptInvite` |

The shell uses `StatefulShellRoute.indexedStack` with a `NavigationBar` (Home, Activity, Sync). The FAB "Add expense" (Vial, extended) appears on Home and Group detail only.

### 10.2 UI rules

- All copy lives in `lib/ui/strings.dart`, taken from DESIGN 7. Never use the words "offline", "device" or "user" in copy.
- Amounts come only from `MoneyFormat` (real minus sign U+2212). Direction words are fixed (DESIGN 7.2).
- Haptics follow DESIGN 4.5, gated by `AppSettings.vibration`.
- Respect `MediaQuery.disableAnimationsOf`, and test at text scale 2.0.
- Errors from `LedgerException` / `SyncException` map to copy in `strings.dart`. Do not show raw exception text.
- `lib/ui/dev/` holds `FakeLedgerRepository`, `FakeSyncEngine` and `seedDemoData()`. Run the app with `--dart-define=SETTLEUP_FAKE=true` to use them (bootstrap checks the flag), so screens can be built before WP-B/C land. Widget tests use them.

---

## 11. Test plan

Run everything with `flutter test` (core tests are pure Dart but run under the same command). CI: `flutter analyze && flutter test`.

### 11.1 Core (WP-A), `test/core/`

| File | Covers |
|---|---|
| `money_test.dart` | `parseMinor` (dot, comma, too many decimals, JPY 0 digits, KWD 3 digits, max), arithmetic, currency mismatch throws, JSON round trip, `Currencies.of` fallback for unknown codes. |
| `hlc_test.dart` | tick monotonic under a frozen clock and a clock going backwards; receive rules (all 4 branches); counter overflow rolls millis; skew guard; `encode`/`parse` round trip; string order == `compareTo` (1,000 random pairs). |
| `version_vector_test.dart` | merge, dominates, equality ignores zero entries, JSON. |
| `ops_test.dart` | `Operation` JSON round trip; malformed inputs throw `FormatException`; newer-schema passthrough keeps `raw`. |
| `split_test.dart` | Every vector in 6.1; property: for 5,000 random specs, Σ shares == total, and the result is identical when map insertion order is shuffled. |
| `balances_test.dart` | nets sum to zero; pairwise vector (6.3); merged and removed members; deleted and inconsistent expenses excluded; multi-currency kept separate. |
| `simplify_test.dart` | Vectors in 6.4; property: 2,000 random net sets of 2-15 members → transfers ≤ n−1, applying the transfers zeroes every net, output is identical across runs. |
| `summaries_test.dart` | people and overall consistency (`overall.net == Σ myNetInGroup`), direct groups, me not a member. |
| `reducer_test.dart` | Each row of the 7.2 conflict table; idempotence (apply twice); invisible-until-create; wrong-type fields ignored; newer schema skipped. |
| `convergence_test.dart` | **The key test.** Seeded random: 3 simulated devices, each with its own `HlcClock` (with clock skew), generate 300 ops (create group/members, add/edit/delete/restore expenses, concurrent money edits, merges, removals). Replica A applies them in a random order, replica B in another random order with 20% duplicates. Assert `A.state.toCanonicalJson()` deep-equals B's, and `groupNets`/`suggestedTransfers` are equal. Repeat for 200 seeds. |
| `activity_test.dart` | kinds, before/after changes, `supersededBy` on a concurrent money edit, newest first. |
| `categories_test.dart`, `csv_export_test.dart` | suggest ("Uber to airport" → transport.taxi, "Tesco" → food.groceries), unknown id → general; CSV escaping (commas, quotes, newlines), CRLF line ends, column order. |

### 11.2 Data (WP-B), `test/data/`

- `op_store_contract_test.dart`: one shared suite run against **both** `MemoryOpStore` and `SqliteOpStore(':memory:')`: insert-or-ignore, contiguous VV with gaps (insert 1,2,4 → vv 2; then 3 → vv 4), `missingFor` ordering and third-party ops, fork rejection, peer knowledge, kv, sync records, purge.
- `ledger_test.dart`: every command produces the expected ops and snapshot; counters contiguous; `updateExpense` writes only changed fields; validation errors; undo flows; startup replay gives the same snapshot; unshared counts drop after `recordPeerKnowledge`; `applyRemote` rejects a batch with a bad op.
- `settings_test.dart`: first launch creates a device identity; onboarding creates a personId once; streams emit the current value first.

### 11.3 Sync (WP-C, D1, D2), `test/sync/`

- `codec_test.dart`: every message type round trips; gzip flag above 1 KiB; unknown type → `bad_frame`.
- `crypto_test.dart`: handshake over `MemoryTransport` with 1 and 3 shared groups gives equal keys and a matching `verificationCode`; wrong key → `auth_failed`; tampered ciphertext → closed; replayed/reordered frame → closed; no shared groups → `noSharedGroups`.
- `session_test.dart` (end to end, two `Ledger(MemoryOpStore)` instances, `MemoryTransport`):
  - fresh joiner receives the whole group; snapshots become canonically equal;
  - both sides have concurrent edits → equal after one session;
  - **gossip:** A↔B, then B↔C → C has A's ops; A and C converge without meeting;
  - batching with `maxFrameBytes = 16 KiB` and 2,000 ops (BLE-sized frames);
  - drop the connection mid-transfer (`dropAfterFrames`) → partial outcome; a second session completes; no duplicates;
  - `busy` when a second inbound connection arrives;
  - live mode pushes a new local op to the peer within 1 s.
- `links_test.dart`: invite and connect links round trip; bad keys/versions → null.
- `lan/tcp_framing_test.dart`: split and coalesced reads, oversize length → close. `lan/loopback_test.dart`: real `ServerSocket` on 127.0.0.1, full session between two engines.
- `bluetooth/ble_chunker_test.dart`: chunk/reassemble at MTU 23, 185, 517; sequence wrap at 256; missing chunk → error. `bluetooth/nearby_endpoint_name_test.dart`: endpoint name encode/parse.
- Real-radio tests (Nearby, BLE, mDNS, hotspot) are a **manual checklist** in `docs/QA.md` (WP-D1/D2 write it): Android↔Android over hotspot, Android↔Android over Nearby, Android↔iOS over BLE, three-phone gossip.

### 11.4 UI (WP-E, WP-F)

- `test/theme/theme_test.dart`: both themes build; `MoneyColors` present; contrast spot checks for owed/owe on surface.
- `test/ui/widgets/*_test.dart`: each widget in light and dark at text scale 1.0 and 2.0 with no overflow; `MoneyFormat` cases (minus sign, JPY, signed).
- `test/ui/screens/smoke_test.dart` with `ProviderScope` overrides (fakes):
  1. No profile → onboarding; entering a name enables "Get started".
  2. Seeded data → Home shows the hero sentence and group rows with direction words.
  3. Add expense: type 60.00, description, Save → `FakeLedgerRepository` received a draft with total 6000 and an equal split.
  4. Split editor: exact amounts that do not sum to the total keep Done disabled and show "left to assign".
  5. Group detail Balances tab shows suggested payments; toggling simplify calls `updateGroup`.
  6. Sync tab renders every `SyncStatus` variant from `FakeSyncEngine` without exceptions.

### 11.5 Architecture

`test/architecture_test.dart` fails if a file under `lib/core` imports `package:flutter`, `dart:io` or `dart:ui`, or if any import rule in 3.2 is violated.

---

## 12. Cloud phase notes (Phase 2, not built now)

Nothing in the MVP is P2P specific. The server is "just another peer".

- **Storage:** Postgres tables that mirror SQLite: `ops(op_id uuid pk, group_id uuid, device_id uuid, counter int, hlc text, schema_ver int, body jsonb or ciphertext bytea, unique(group_id, device_id, counter))`, `version_vector(group_id, device_id, max_counter)`. UUIDv7 keys index well.
- **API:** `POST /v1/groups/{id}/ops` (batch upload, idempotent on `op_id`, returns the server VV), `GET /v1/groups/{id}/ops?vv=<base64 JSON>` (delta download, paginated), and `WS /v1/sync` running the **same message set** (VV/OPS/ACK/DONE) inside TLS, so `SyncSession` is reused with a `WebSocketTransport` implementing `SyncTransport`/`FrameChannel`.
- **Auth:** accounts become optional. A device registers with a public key; group membership on the server is proven by a group-key MAC (same blinded scheme) or by invite tokens issued by the server.
- **Privacy option (E2E):** the server stores `{opId, groupId, deviceId, counter, hlc, ciphertext}` where the ciphertext is AES-GCM under a key derived from the group key. The server can compute VVs but cannot read expenses.
- **Integrity:** Ed25519 per device; ops signed over `(id, groupId, deviceId, counter, hlc, canonical payload)`. Add a `sig` field in schema v2. The server and peers verify.
- **Membership:** group key rotation on member removal, distributed per device (X25519 to each device's static key). Add `link_member` ops to tie a member to an account `userId`; add multi-device per person (transfer all group keys through an authenticated pairing).
- **Blobs:** receipt images in object storage, addressed by sha256 (already the reference format for v1.1).
- **Other server features:** push notifications on new ops, email summaries, FX rates service, web viewer by share link.
- **Client changes needed:** a `CloudTransport`, background sync (WorkManager / BGTaskScheduler), and a "Sync with cloud" toggle per group. The data and core layers stay unchanged.

---

## 13. Build order

| Phase | Who | What | Exit criteria |
|---|---|---|---|
| 0 | integrator | Write `pubspec.yaml` (2.2), `analysis_options.yaml` (2.3), copy every section 5 contract file verbatim, add a stub `lib/main.dart` that compiles, add `test/architecture_test.dart`. Commit. | `flutter pub get`, `flutter analyze` clean |
| 1 (parallel) | WP-A, B, C, D1, D2, E, F | Each in its own directories. B, C and F use fakes until A lands; C tests with `MemoryOpStore` once B's lands (or its own fake `SyncStore`). | Each package's own tests green |
| 2 | integrator | Merge order A → B → C → D1 → D2 → E → F. Wire `bootstrap.dart` with the real classes. Run the full test suite. | `flutter analyze && flutter test` green; `flutter build apk --debug` succeeds |
| 3 | WP-D1/D2 + F | Manual radio QA (`docs/QA.md`) on 2 Android phones (+1 iPhone for BLE). Fix transport bugs. | QA checklist passes |
| 4 | any | P1 items in order (1.2) | |

If a frozen contract turns out to be wrong during Phase 1, the owner of the contract file proposes the change to the tech lead with the reason. All affected packages update in the same merge.
