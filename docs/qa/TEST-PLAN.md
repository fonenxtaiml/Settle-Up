# Settle Up: production QA test plan

Owner: QA lead. Branch: `qa/integration` (cut from `dev` at `854df42`,
"Release 0.1.0: wire real storage and sync into startup").
Inputs: `docs/SPEC.md` (sections 1, 5.16, 6, 7, 8, 9, 11), `docs/design/DESIGN.md`
and the approved renders in `docs/design/point-to-point/*.png`, `docs/QA.md`
(manual radio checklist), and the code on `dev`.

This plan decides what "ready for production" means for the 1.0.0 Android
release, which risks matter most, how each one is tested without a phone, and
what is left for the device pass.

---

## 1. Baseline (dev at 854df42)

| Check | Result |
|---|---|
| `flutter pub get` | OK (11 packages have newer, constraint-incompatible versions; pins in SPEC 2.1 are intentional) |
| `flutter analyze` | No issues |
| `flutter test` | All 866 tests passed (about 1 min 6 s on the shared 4-CPU host) |

Observations from the first read (to be confirmed or closed by the area
owners, they are not findings yet):

- `lib/main.dart` awaits `bootstrap()` with no error handling. Any throw while
  opening SQLite, secure storage or a transport constructor ends in a blank or
  crashed first frame.
- `android/app/build.gradle.kts` signs `release` with the debug key and still
  carries template TODOs; no R8/proguard rules file exists.
- `pubspec.yaml` is `0.1.0+1`; production target is `1.0.0+N`.
- The launcher icon in `mipmap-*` is 544 bytes in hdpi, which looks like the
  stock Flutter icon.
- `README.md` is a single heading; no build, run or release instructions.
  No privacy policy or store listing text.
- SPEC 10 names Atkinson Hyperlegible Next, DESIGN.md and `assets/google_fonts`
  use Familjen Grotesk. DESIGN.md is the visual source of truth, so the
  bundled font is expected; the SPEC line is stale.
- Router redirect: a `settleup://join` link opened before onboarding is
  redirected to `/join`, then to `/onboarding`; the invite may be lost.
- `android/gradle.properties` asks for an 8 GB Gradle heap, which may not fit
  on CI or developer machines.

---

## 2. Product risks, ranked

Likelihood (L) and impact (I) on a 1 to 5 scale. Score = L x I. The order is
the order of test effort.

| Rank | Risk | L | I | Score | Why it matters |
|---|---|---|---|---|---|
| R1 | **Money correctness**: wrong shares, rounding drift, wrong balances, simplify changing a net, settle-up suggesting the wrong amount, currencies mixed | 3 | 5 | 15 | The whole product is "who owes whom". One wrong rupee destroys trust and is shared to every friend's phone. |
| R2 | **Sync convergence and security**: phones disagree after sync, ops lost or duplicated, a stranger or wrong key gets in, keys leak | 3 | 5 | 15 | Divergence is silent and spreads by gossip. A leak exposes a group's finances. |
| R3 | **Data loss**: op log not durable across restarts, failed write leaves a half state, schema upgrade drops ops, corrupt row bricks startup | 2 | 5 | 10 | No cloud backup and auto-backup is disabled on purpose, so local loss is permanent. |
| R4 | **Crash on launch / startup path**: bootstrap throws, plugin missing in release (R8), migration error | 2 | 5 | 10 | A crash on launch means a 1-star app and no way to recover data from the UI. |
| R5 | **Permissions and radios**: denied permissions, Bluetooth or Wi-Fi off, no Google Play services, API 26 to 36 differences | 4 | 3 | 12 | Sync is a headline feature; most real failures happen here and cannot be unit tested end to end. |
| R6 | **UX and accessibility**: broken flows, lost input, overflow at large text, unreadable contrast, unlabeled controls, wrong copy/direction words | 3 | 3 | 9 | Hurts adoption and is a store-review risk; direction words carry money meaning. |
| R7 | **Release readiness**: debug signing, wrong version, default icon/name, missing docs, debug flags, build not reproducible | 4 | 2 | 8 | Blocks publishing; cheap to fix once found. |

R5 ranks above R3/R4 on score but below them in priority, because R3/R4 are
irreversible for the user and R5 mostly has a retry path.

---

## 3. Test strategy per risk

Three kinds of evidence, used in this order:

1. **Automated under `flutter test`** (no device): pure Dart unit tests,
   integration tests over the real `Ledger` with `MemoryOpStore` and
   `SqliteOpStore` (file and `:memory:`), real `DefaultSyncEngine` over
   `MemoryTransport` and loopback `LanTransport` (127.0.0.1 sockets), and
   widget tests with the real `Ledger` + `KvSettingsRepository` wired through
   `ProviderScope` (not the `lib/ui/dev` fakes, which the existing smoke tests
   already use).
2. **Static review** of code, manifest, Gradle, docs, against the spec and
   platform rules; plus a local `flutter build apk --release` to prove the
   release build and R8 work. (No APK is handed out from QA.)
3. **Manual device checklist** (section 7) for what only phones can show.

| Risk | Automated | Static review | Device only |
|---|---|---|---|
| R1 Money | Property tests over `SplitCalculator`/`BalanceCalculator`/`DebtSimplifier`/`Summaries`; end-to-end scenario tests through `Ledger` commands and the Riverpod providers (`groupNetsProvider`, `groupTransfersProvider`, `peopleBalancesProvider`, `overallBalanceProvider`); CSV golden output | Every `double` near money (SPEC 0.5); `MoneyFormat` and amount parsing paths | Locale keyboards (comma decimal) on a phone |
| R2 Sync | Multi-phone harness: 2-3 `Ledger`s + `DefaultSyncEngine` over `MemoryTransport` (fault injection: `dropAfterFrames`, latency, tiny `maxFrameBytes`) and over loopback LAN; canonical snapshot equality; adversarial peers | Crypto usage (nonces, key schedule, constant-time compare, key storage), op validation in `applyRemote`, logging of secrets | Real hotspot, Nearby, BLE, mDNS (docs/QA.md 2 and 4) |
| R3 Data | `SqliteOpStore` on a temp file: write, close, reopen, compare; injected failures; corrupt rows; `user_version` handling; 20k-op timing | Transactions, WAL, error paths in `sqlite_op_store.dart`, `ledger.dart` | Kill the app mid-sync; low storage |
| R4 Startup | Test `realOverrides()`-equivalent wiring with fakes for platform channels; startup with corrupt/old/newer DB | `main.dart`, `bootstrap.dart`, every constructor reached before `runApp`; R8 keep rules | Cold start on API 26 and 36, release build |
| R5 Radios | `NearbyPermissions` with fake platform per API level; transports report `off`/`denied`/`unsupported` without throwing; engine falls back lan to nearby to ble | Manifest permissions vs SPEC 9.1 after merge (`aapt dump permissions` / merged manifest) | docs/QA.md 3 and 4 on API 29/30, 31/32, 34+; phone without Play services |
| R6 UX | Widget flows on real Ledger; golden/overflow at 320x568, 360x640, text scale 1.3 and 2.0, dark; semantics and tap target guideline tests (`meetsGuideline`) | Copy in `strings.dart` vs DESIGN 7 and SPEC 10.2 (no "offline/device/user"); compare with renders | TalkBack pass; real keyboard and back gesture |
| R7 Release | `flutter build apk --release` locally; version and label checks | Gradle signing, icon, app name, version, README, privacy policy, store listing | Install over an older build |

---

## 4. Severity definitions

| Severity | Definition | Examples |
|---|---|---|
| **Blocker** | Release cannot ship; no workaround; data or money is wrong, lost or exposed, or the app cannot start | Wrong balance or share; phones diverge after sync; op lost on restart; crash on launch; group key in logs; release build fails |
| **Critical** | A P0 feature is broken or unsafe for many users; workaround is unreasonable | Settle up records the wrong currency; a sync transport always fails; denied permission crashes; release signed with debug key |
| **Major** | A feature works incorrectly in a common case, or an accessibility failure blocks a task; a workaround exists | Undo does not restore; text overflow hides an amount at 1.3x; button without a semantics label; missing error copy |
| **Minor** | Cosmetic or edge-case functional issue that does not change money or data | Misaligned row in dark mode; wrong copy tense; tap target 44dp on a secondary control |
| **Trivial** | Polish, typos, doc nits | Comment typo; inconsistent spacing in README |

Every finding records: id (`<AREA>-NN`), severity, steps or failing test,
expected vs actual, file:line, and the test that proves the fix.

---

## 5. Entry and exit criteria

**Entry** (met at 854df42):

- All feature PRs merged into `dev`; `qa/integration` cut from it.
- `flutter analyze` clean and `flutter test` green on the baseline.

**Exit** (all required):

1. **Zero open findings of any severity** (blocker through trivial) in every
   area. A finding is closed only when a separate engineer fixed it on a
   `fix/*` branch merged into `dev`, and QA re-verified it on `qa/integration`
   after merging `dev` back.
2. Every new QA test is committed and passes; the full suite is green; `flutter
   analyze` reports no issues (infos included).
3. `flutter build apk --release` succeeds locally with R8 on, using an untracked
   `key.properties` when present and a documented fallback when absent.
4. Production metadata: version `1.0.0`, app name "Settle Up", custom launcher
   icon, no debug flags, README run/build/release instructions, privacy policy
   and store listing docs in the repo.
5. Device-only checks in section 7 are listed with owner and status. They do not
   block the QA report being clean, but the report must say which were not
   run because no device was available.

**Suspension**: a blocker in R1 to R4 pauses the other areas' sign-off until
fixed, since fixes there touch shared code.

---

## 6. QA areas and charters

Each area has one QA owner who writes tests under `test/qa/<area>/` (pure
`flutter test`, no device), files findings, and re-verifies fixes. QA does not
fix product code.

### MONEY: money correctness end to end

Through the real `Ledger(MemoryOpStore)` + providers, not only `lib/core`.

- Every split method (equal, exact, percent, shares, adjustment) with the SPEC
  6.1 vectors re-run through `Ledger.addExpense`, plus: total 1 minor unit over
  3 people, 999,999,999 (`Money.maxMinor`) with 50 members, percent 3333/3333/3334,
  shares 1000:1, adjustment that makes `rest` exactly 0, adjustment negative
  but valid, zero-weight participants dropped.
- Rounding: ties go to lowest member id regardless of insertion order; JPY
  (0 digits), KWD (3 digits) and INR amounts; Σ shares == total always.
- Multiple payers: exact, equal-among-payers, percent and shares on the payer
  side; payer who is also an ower; payer not an ower; pairwise debts split in
  proportion to paid (SPEC 6.3 vector).
- Edits (amount, split, payer, currency change), delete, restore, edit after
  delete then restore (SPEC 7.2 conflict table), payments edited via
  `updatePayment`; balances recomputed each step.
- Group nets sum to zero per currency after every command (invariant check in
  each scenario).
- Simplify on vs off: same nets; transfers ≤ n−1; toggling does not change
  per-person totals; settled group shows nothing.
- Settle up: exact, partial, over-payment (direction flips), payment recorded
  by the creditor side, payment in a second currency settles only that
  currency, duplicate payment hint.
- Merged and removed members keep balances; merge cycles resolve.
- Person and overall summaries: `overall.net == Σ myNetInGroup` per currency;
  direct (friend) groups; me not a member; hero currency choice (home currency,
  else largest).
- CSV export: column order, escaping, CRLF, minus sign, formula-leading cells
  (`=`, `+`, `-`, `@`, tab, CR), multi-currency, deleted expenses excluded.
- Static: no `double` in money paths; amount parsing of "1,234.50", "1.234,50",
  "12.345" for KWD, too many decimals.

### SYNC: multi-phone convergence through the real engine

Real `DefaultSyncEngine` + `Ledger` over `MemoryTransport` and loopback
`LanTransport`.

- Invite/join/claim: `inviteLinkFor` → `acceptInvite` → first sync gives the
  joiner the whole group → `claimMember` syncs back; joining twice; joining a
  group you already have; invite with `h=` host hint.
- Concurrent offline edits on 2 phones (same field, different fields, edit vs
  delete, both add "Bob"), then sync: canonical snapshots equal on both.
- Interrupted sync (`dropAfterFrames` at several points, including mid-batch
  and after the last ACK but before DONE): outcome `partial`, nothing applied
  twice, second session completes, unshared counts correct.
- 3-phone gossip: A↔B then B↔C then C↔A; A and C converge without meeting;
  ring of syncs reaches a fixed point.
- Clock skew: one phone 2 h ahead and one 1 day behind; convergence holds;
  `skewDetected` set; LWW winner is deterministic.
- Wrong keys / no shared group / tampered frames / replayed HELLO: session fails
  with the right reason, no ops applied, no crash, engine accepts the next
  session.
- Large groups: 2,000+ ops with 16 KiB frames (BLE size), 50 members; batching
  window of 4; progress events rate limited.
- Repeated syncs are idempotent: sync 5 times, op count and snapshot unchanged,
  sync records added each time.
- Engine orchestration: one session at a time (`busy`), cancel mid-session,
  hosting expiry, transport fallback order lan → nearby → ble, `syncWithLink`
  with unreachable hosts.
- Newer-schema ops relayed byte for byte and not applied.

### DATA: durability and performance

- `SqliteOpStore` on a temp file: commands, close, reopen `Ledger` on the same
  file → identical canonical snapshot, profile, settings, device id, HLC not
  going backwards, counters contiguous (no reuse after restart).
- Schema/version: fresh DB gets `user_version = 1`; DB with `user_version = 0`
  and existing tables; DB from a newer version (`user_version = 2`) does not
  crash or wipe data.
- Corrupted rows: invalid JSON in `ops.json`, unknown entity type, missing
  fields, bad `kv` values (profile/settings/device) → startup survives, bad row
  skipped and logged, other data intact.
- Failed writes: store throws during `insertAll` → in-memory state not advanced,
  counter not burned, command reports `LedgerException`, next command works.
- Forked device (same device/counter, different op id) kept first.
- Performance: 20k ops across 10 groups: open + replay time, snapshot rebuild
  time per command, memory estimate; budget open < 2 s on the host as a proxy.
- Unshared counts: per group and total, after local edits, after
  `recordPeerKnowledge`, after restart.
- Group key store: keys survive reopen; missing key for a group with ops.

### UIFLOW: functional flows on the real Ledger

Widget tests with `Ledger(MemoryOpStore)` + `KvSettingsRepository` + a stub
sync engine (or real engine over `MemoryTransport`).

- Onboarding → home empty state → create group (name limits, currency, type,
  emoji, simplify) → add members (duplicate names, limit 50) → add expense with
  each split method via the split editor (live remainder, Done disabled when
  unbalanced) → group balances → settle up → home hero updates.
- Delete expense → undo snackbar → restore from detail; edit expense keeps
  untouched fields; payment edit.
- Activity feed (group and global) shows each command; search finds by
  description, notes, category label and member name.
- Settings: name, home currency, theme, vibration, phone name, CSV export (share
  sheet stubbed).
- Navigation: back stack from deep screens, shell tabs keep state, Android back
  on root, FAB only on Home and Group.
- Deep links: `settleup://join?...` before and after onboarding (invite must not
  be lost), malformed link, `settleup://sync?...`.
- Validation and error copy: every `LedgerException` / `SyncException` maps to
  copy from `strings.dart`; no raw exception text; no "offline/device/user"
  words in copy.

### VISUAL: visual quality, accessibility and i18n

- Every main screen at 320x568 and 360x640, text scale 1.0, 1.3, 2.0, light and
  dark: no overflow exceptions, amounts never truncated without ellipsis
  strategy.
- Long names (40 chars member, 60 chars group, 120 chars description) and huge
  amounts (`Money.maxMinor` in INR and KWD) in rows, hero, settle screen.
- Empty states on Home, Group, Activity, Search, Sync.
- Semantics: amounts read with direction word and sign; icon buttons labeled;
  tether and avatars have labels or are excluded; `meetsGuideline` for
  `androidTapTargetGuideline` (48dp), `labeledTapTargetGuideline`,
  `textContrastGuideline` in both themes.
- Money formatting: JPY (no decimals), KWD (3), USD, EUR, INR (lakh grouping if
  specified), U+2212 minus, signed vs unsigned.
- Compare screens with `docs/design/point-to-point/1-6*.png`: colour only for
  money direction, tabular figures, 20px gutter, no leading icon tiles on group
  rows, settled never green.
- `MediaQuery.disableAnimations` respected (bubble animation, tether).

### SECURITY: security and privacy

- Invite links and QR: key encoding, `links.dart` parsing of bad versions/keys,
  QR auto-hide after 2 min, explicit share warning, connect links carry no
  secrets.
- Crypto: X25519 ephemeral per session, HKDF inputs, per-direction nonces never
  reused, constant-time MAC compare, AES-GCM tag checks, frame counter rules,
  blinded group ids and token rotation.
- Op validation from peers: oversized ops, wrong group id, entity in another
  group, non-contiguous counters, forged device id, huge strings, deep JSON,
  numbers out of range, type confusion; engine survives and rejects with
  `bad_op`.
- Secrets in logs: grep and test that no group key, invite link or decrypted
  payload is logged (`developer.log`, exception messages, SyncRecord JSON).
- Storage: `flutter_secure_storage` options on Android, behaviour after
  key loss, keys not in SQLite or kv.
- Android manifest: exported components (only the launcher activity, intent
  filters for `settleup://` only), `allowBackup=false` and data extraction rules
  for API 31+, `usesCleartextTraffic`, permission minimization after manifest
  merge.
- CSV/formula injection and input limits (SPEC 5.16) enforced in `Ledger`, not
  only in the UI; trimming; control characters and RTL override characters in
  names.

### PLATFORM: Android platform and production readiness

- Startup path: every await in `main.dart` / `bootstrap.dart` and constructors
  reached before `runApp`; behaviour when `getApplicationSupportDirectory`,
  SQLite open, secure storage, `device_info_plus` or a transport constructor
  throws (must show an error screen or degrade, never crash).
- Radios: transports report availability without throwing when Bluetooth or
  Wi-Fi is off, permission denied or permanently denied, Nearby on a phone with
  no Google Play services, iOS path for Nearby is `unsupported`.
- API 26 to 36 differences in `permissions.dart` and the merged manifest
  (location ≤ 32, `NEARBY_WIFI_DEVICES` 33+, BLUETOOTH_* 31+).
- Release build: `flutter build apk --release` succeeds; R8 keep rules for
  `nearby_connections`, `bluetooth_low_energy`, `mobile_scanner`,
  `flutter_secure_storage`, `bonsoir`, `cryptography_flutter`; no missing-class
  warnings.
- App icon is custom (not the Flutter default) in all densities plus adaptive
  icon; app label "Settle Up"; version `1.0.0+N`; `applicationId` final.
- Release signing via untracked `android/key.properties` (gitignored) with a
  documented debug fallback and a loud log when falling back.
- No debug flags: `SETTLEUP_FAKE` off by default, no `debugShowCheckedModeBanner`,
  no dev screens reachable, template TODOs removed.
- Docs: README run/build/test/release instructions, privacy policy (local only,
  what radios and camera are used for, no data collected), store listing text.
- Build environment: Gradle heap setting workable on a 4-CPU/limited-RAM host.

---

## 7. Device-only checks (cannot run in this environment)

No emulator or phone is available, so these stay open as listed items, owned by
the release manager, and are reported separately from findings:

1. docs/QA.md section 2: LAN and hotspot sync (router, Android hotspot, iPhone
   Personal Hotspot, edge cases).
2. docs/QA.md section 3: permission dialogs on API 29/30, 31/32, 34-36,
   including "Don't allow" and "Don't ask again".
3. docs/QA.md section 4: Nearby Connections, BLE Android↔Android and
   Android↔iPhone, three phones over Bluetooth only.
4. Cold start of the release APK on API 26 and on API 36; upgrade install over
   0.1.0 keeps data.
5. Phone without Google Play services (Nearby unavailable, LAN and BLE still
   work).
6. TalkBack walkthrough of the main flow; system font size largest; display
   size largest.
7. QR scan in low light; camera permission denied then granted in settings.
8. Kill the app during a sync and during an expense save; reopen.
9. Real keyboard input for amounts with a comma decimal locale.

---

## 8. Workflow

1. QA areas write tests and file findings (`<AREA>-NN`) against
   `qa/integration`.
2. A separate pool of senior engineers fixes each finding on `fix/<area>-<nn>-*`
   branches from `dev`, with a regression test, through a PR into `dev`.
3. QA merges `dev` into `qa/integration` and re-verifies; a finding closes only
   on QA re-verification.
4. Loop until every area reports zero open findings and the exit criteria in
   section 5 hold.

---

## 9. Baseline run log

Run on `qa/integration` at 854df42, 2026-11-09:

```text
flutter pub get   Got dependencies! (11 packages have newer incompatible versions)
flutter analyze   No issues found! (ran in 3.7s)
flutter test      01:06 +866: All tests passed!
```
