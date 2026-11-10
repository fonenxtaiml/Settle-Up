# Settle Up 1.0.0: QA report

Owner: QA lead. Branch: `qa/integration` at the commit that adds this file
(parent `715fbce`). Baseline: `dev` at `854df42`. Date: 2026-11-10.
Plan: [TEST-PLAN.md](TEST-PLAN.md). Manual radio checklist:
[../QA.md](../QA.md).

## 1. Verdict

**The report is not clean. 10 findings are still open (9 minor, 1 trivial).
Zero blockers, criticals or majors are open.**

**Release recommendation: NO-GO for the 1.0.0 production release yet.** The
exit criteria in TEST-PLAN.md section 5 require zero open findings of any
severity. Four further conditions also stand between this branch and a
release, whatever happens to the open findings:

1. **The fixes are not on `dev`.** `origin/dev` is still the baseline
   `854df42`. `qa/integration` is 308 commits ahead and holds every fix
   verified in this report. Bring it into `dev` with `tool/squash_merge.sh`
   (see 7.2), re-run `flutter analyze` and `flutter test` on `dev`, and build
   the release from `dev`/`main`, not from this branch.
2. **Release signing.** No `android/key.properties` exists on this host, so
   the local release build is signed with the debug key (the build prints the
   PLATFORM-R2-02 warning). The final APK must be built with the real upload
   key (README "Release signing").
3. **The device pass in section 6 has not been run.** No emulator or phone
   was available. Radios, permissions, keyboards, the Keystore, deep-link
   intents and R8 at runtime are verified only by static review and host
   tests.
4. Round 7 must re-verify the fixes for the 10 open findings, and confirm
   that they bring no regressions (rounds 2 to 6 each found new defects next
   to the previous fixes).

What would be acceptable instead: the 10 open findings are all edge cases
(unusual pasted text in the amount and split fields, invisible-character
names, a cosmetic name flip, a wrapped label, a 1970 clock). None of them
loses or corrupts stored data, and none affects sync convergence or security.
If the owner chooses to ship a **tester build** for the device pass now, that
is reasonable once conditions 1 and 2 are met, with these 10 findings listed
as known issues. A Play production release should wait for a clean round.

## 2. Scope and environment

**In scope:** everything in the app on `dev` at `854df42` plus all fixes since:
`lib/core` (money, split, balance, reducer), `lib/data` (SQLite op log,
Ledger, migrations, key storage), `lib/sync` (protocol, engine, LAN/mDNS,
Nearby, BLE, permissions), `lib/ui` and `lib/theme` (all screens, router,
providers, design system), `lib/bootstrap.dart`, the Android project
(manifest, Gradle, R8, resources, signing), and the docs (SPEC, README,
PRIVACY, STORE-LISTING, release notes). Spec sources: `docs/SPEC.md`,
`docs/design/DESIGN.md` and the approved Point to Point renders.

**Out of scope here:** iOS builds (no macOS host), real radios, real
keyboards, TalkBack and anything that needs a phone. Those are in section 6.

| Item | Value |
|---|---|
| Host | Linux, 4 CPUs shared with other agents, no KVM, no emulator, no phone |
| Flutter / Dart | 3.47.9 / 3.13 (`/opt/sdk/flutter`) |
| Android SDK | `/opt/sdk/android`; compileSdk 37, targetSdk 36, minSdk 26 |
| App under test | `app.settleup.settleup`, versionName 1.0.0, versionCode 2 |
| Test doubles | Real `Ledger` over `SqliteOpStore` (file and `:memory:`) and `MemoryOpStore`; real `DefaultSyncEngine` over `MemoryTransport` and loopback `LanTransport` (127.0.0.1); widget tests with the real Ledger and settings, the bundled Familjen Grotesk TTFs, 320/360/411 dp and 1.0x to 2.0x text, light and dark |
| Not available | Radios (BLE, Nearby, Wi-Fi Direct/hotspot), Android Keystore, ML Kit camera, IME, intents |

## 3. Test plan summary

Seven QA areas, each with one owner and its own tests under `test/qa/<area>/`
(full charters in TEST-PLAN.md section 6):

| Area | Charter |
|---|---|
| MONEY | Split methods, rounding, balances, simplify, settle up, multi-currency, multi-payer, CSV, and amount parsing in every input (typing, paste, locales, separators, signs) |
| SYNC | Convergence through the real engine, adversarial and interrupted sessions, discovery tokens, clock skew, mutual and third-party Sync, cancel, invites, LAN loopback, scale |
| DATA | Durability across restarts, failed and partial writes, corrupt rows, schema migrations, startup failures, performance (20k ops), names and CSV file names |
| UIFLOW | Onboarding, groups, members, expenses, settle up, activity, search, settings, deep links, back navigation, validation copy |
| VISUAL | Layout matrix (320/360/411 dp x 1.0-2.0x x light/dark), design rules, money format, semantics, reduce motion, empty states |
| SECURITY | Crypto, op validation, engine abuse, input limits, key storage and Keystore loss, manifest, invite QR, dates and currencies from peers |
| PLATFORM | Startup, permissions and radio states, release readiness (version, signing, icon, R8, docs), commit-message policy |

Workflow (TEST-PLAN.md section 8): QA files findings and writes a failing
repro; a separate pool of senior engineers fixes each one on a `fix/*` branch
with a regression test; QA merges and re-verifies; a finding closes only on QA
re-verification. Six rounds were run. Repros for open findings stay in the
suite as `skip:` tests, so the suite is green and the fix flips them on.

Severity scale: TEST-PLAN.md section 4 (blocker, critical, major, minor,
trivial).

## 4. Metrics

### 4.1 Final run (this commit's parent, `715fbce`)

| Check | Result |
|---|---|
| `flutter analyze` | **No issues found** (infos included) |
| `flutter test` (full suite) | **2,463 tests: 2,447 passed, 16 skipped, 0 failed** (11 min 34 s on the shared host) |
| `flutter test test/qa` | 1,288 tests: 1,272 passed, 16 skipped (the 16 skips are the repros of the 10 open findings) |
| `flutter build apk --release` | **Built** `app-release.apk` (108.0 MB, all ABIs), R8 on, `mapping.txt` produced. `aapt2`: package `app.settleup.settleup`, versionCode 2, versionName 1.0.0, minSdk 26, targetSdk 36. Signed with the **debug key** because `android/key.properties` is absent (warning printed). Build check only; the APK was not published or handed out. |

### 4.2 Tests

| | Count |
|---|---:|
| Baseline suite at `854df42` | 866 |
| Final suite | 2,463 |
| Added by QA (`test/qa/**`) | **1,288** (data, money, platform, security, sync, uiflow, visual) |
| Added by the fix engineers (regression tests outside `test/qa`) | 309 |
| Skipped (failing repros of open findings) | 16 |

### 4.3 Findings by area and severity (all rounds)

| Area | Blocker | Critical | Major | Minor | Trivial | Total | Open |
|---|---:|---:|---:|---:|---:|---:|---:|
| MONEY | 0 | 1 | 10 | 15 | 0 | 26 | 4 |
| SYNC | 0 | 1 | 5 | 9 | 0 | 15 | 1 |
| DATA | 0 | 1 | 3 | 9 | 8 | 21 | 2 |
| UIFLOW | 0 | 0 | 11 | 19 | 2 | 32 | 1 |
| VISUAL | 0 | 0 | 10 | 19 | 2 | 31 | 1 |
| SECURITY | 0 | 0 | 9 | 13 | 2 | 24 | 1 |
| PLATFORM | 1 | 2 | 5 | 6 | 2 | 16 | 0 |
| **All** | **1** | **5** | **53** | **90** | **16** | **165** | **10** |

Closed: 155, all **closed, fixed** (re-verified by QA). Closed as not a
defect: 0. Open: 10. Reopen events: 22 on 18 distinct findings (a fix that
did not hold in re-verification is reopened, not duplicated).

### 4.4 Rounds

| Round | New findings | Re-verified and closed | Reopened | Open at end of round |
|---|---:|---:|---:|---:|
| 1 | 87 | 0 | 0 | 87 |
| 2 | 28 | 77 | 10 | 38 |
| 3 | 17 | 36 | 2 | 19 |
| 4 | 17 | 16 | 3 | 20 |
| 5 | 9 | 16 | 4 | 13 |
| 6 | 7 | 10 | 3 | 10 |

Open findings at the end of each round went 87, 38, 19, 20, 13, 10. Every
open finding is now minor or trivial; the last major closed in round 6.

## 5. Findings

### 5.1 Open findings (10)

Each has a failing repro in the suite, marked `skip:` with the finding id.

| ID | Severity | Summary of what is still wrong | Repro (skipped) |
|---|---|---|---|
| MONEY-R3-05 | Minor | A multiplier after a currency symbol, a currency word or an invisible mark is dropped: '1.5 € million' and '1.5 EUR million' give €1.50, '2.5$k' gives $2.50, '5 Rs lakh' gives ₹5; '2.5' + ZWSP/LRM/soft hyphen + 'k' gives $2.50. `_hasUnknownWordAfter` looks only at the first word after the last digit. Expected: a multiplier anywhere after the number makes the text unreadable. (The round 4 and 5 cases, joined numbers and tab/line-break grouping, are fixed.) | `test/qa/money/r6_reverify_test.dart`, group `QA MONEY-R3-05 (reopened)`, 2 tests |
| MONEY-R4-01 | Minor | In a no-decimal currency, a separator typed first is dropped: JPY '.50' typed key by key gives ¥50, ',50' gives ¥50, '.5' gives ¥5 with Save on, while pasting '.50' is refused. Expected: typing and pasting the same text agree, and a dropped separator never lets the next digits make the amount. Low impact. | `test/qa/money/r6_reverify_test.dart`, `QA MONEY-R4-01 (reopened)` |
| MONEY-R4-04 | Minor | Signed adjustment field reads other negative notations as a plus: full-width brackets '（30）', Japanese '▲30' / '△30', heavy minus '➖30', U+02D7, U+FE58, and 'less 30'. On Add expense (total 270, Adjust) pasting '（30）' saves +30: a 60 swing. Expected: read as negative or refused (ideally refuse any unknown non-letter mark before the number in a signed field). | `test/qa/money/r6_reverify_test.dart`, `QA MONEY-R4-04 (reopened)`, 2 tests |
| MONEY-R6-01 | Minor | A dot-grouped number whose last group is short is read as grouping: EUR '1.200.50' typed gives €120,050, a USD paste of '1.200.50' gives $120,050 (or 12,005), with Save on. Expected: a short last group after two or more dots is refused. | `test/qa/money/r6_reverify_test.dart`, `QA MONEY-R6-01`, 3 tests |
| SYNC-R6-01 | Minor | After a rename while visible, a missed mDNS goodbye leaves the old LAN service cached, and the peer's Nearby row flips between the old and new names until the old record expires. Cosmetic: one row, same advert id, and Sync still reaches the right phone. | `test/qa/sync/r6_probes_test.dart`, `SYNC-R6-01` |
| DATA-R6-01 | Trivial | A phone name that shows nothing (U+200B; or U+3164, U+2800, U+115F) is shown as a blank name on the other phone ('Synced with '). `SyncSession.peerName` falls back only on `isEmpty`, not on blank, and the fallback hint is the same phone's advert name. | `test/qa/data/r6_regression_test.dart`, `DATA-R6-01` |
| DATA-R6-02 | Minor | A profile name that shows nothing is accepted at onboarding; afterwards every New group and Add friend fails with 'Your name is empty'. Settings > Edit name has the same gap: the profile is saved first, then `renameMeEverywhere` is refused, so profile and member names disagree. | `test/qa/data/r6_regression_test.dart`, `DATA-R6-02` |
| UIFLOW-R6-01 | Minor | The duplicate-name key drops space-wide fillers (U+115F, U+1160, U+3164, U+FFA0, U+2800), so `Rahul<filler>Kumar` passes the check and shows as a second 'Rahul Kumar'; and `Rahul<U+3164>Kumar` is refused against 'RahulKumar'. Fix: map these fillers to a space in `key()` (`lib/ui/screens/common.dart`, `duplicateName`) before the whitespace collapse, for the comparison only. | `test/qa/uiflow/r6_regression_test.dart`, `UIFLOW-R6-01`, 2 tests |
| VISUAL-R6-01 | Minor | Multi-payer sheet puts 'Split the rest equally' beside 'Done' in a 96 dp (320 dp phone) or 116 dp (360 dp) box: 2 lines at 1.0x, 3 at 1.3x-1.6x, 5 at 320 dp 2.0x, where 'equally' breaks mid-word. Predates round 5; earlier sweeps did not open this sheet. | `test/qa/visual/r6_regression_test.dart`, `VISUAL-R6-01` |
| SECURITY-R6-01 | Minor | On a phone whose clock was reset to 1970, the editors' date picker range is 1970-01-01..1971-12-31, so a new expense can never get the real date and syncs to peers as 1970/1971. (The SECURITY-R5-01 crash is fixed; the picker opens.) | `test/qa/security/r6_date_picker_test.dart`, `SECURITY-R6-01`, 2 tests |

### 5.2 All findings with final status

Status key: **OPEN**; "Closed, fixed (round N)" means fixed by an engineer
and re-verified by QA in round N. "Reopened" is how many times a fix failed
re-verification. No finding was closed as not a defect.

#### MONEY

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| MONEY-R1-01 | Critical | Settle up ignores the currency of the payment the user picked: a second-currency debt can never be settled in the app | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-02 | Major | Amount field reads European '1.234,50' as 1.23 without any warning | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-03 | Major | With simplify off, a fully settled group still lists pairwise payments and per-person debts | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-04 | Major | Grouped amounts in per-member split fields ('1,000') are silently treated as 0; an adjustment is saved without it | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-06 | Major | No 'possible duplicate' hint for two payments of the same debt (SPEC 7.2) | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-07 | Major | Expense rows and the activity feed show 'not involved' for expenses of a member merged into me | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-05 | Minor | CSV Date column is the UTC day, not the day the app shows (off by one outside UTC) | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-08 | Minor | Shares stepper stops at 99 although SPEC 6.1 allows weights 1..1000 | R1 |  | Closed, fixed (round 2) |
| MONEY-R1-09 | Minor | CSV export has no UTF-8 BOM and non-Latin group names give a nameless '.csv' file | R1 |  | Closed, fixed (round 2) |
| MONEY-R2-01 | Major | Typing a comma-grouped amount with two or more commas (1,234,567 / lakh 1,00,000) in the amount field gives a 1000x+ smaller amount | R2 |  | Closed, fixed (round 3) |
| MONEY-R2-02 | Major | Pasting 'Rs. 500' (or 'approx. 300') into the amount field gives ₹0.50 | R2 |  | Closed, fixed (round 3) |
| MONEY-R2-03 | Major | '0,500' is read as thousands grouping: KWD/TND/BHD half a dinar becomes 500 dinars | R2 |  | Closed, fixed (round 3) |
| MONEY-R2-04 | Minor | Amount field: a decimal comma it already shows as '.' flips to a thousands separator when a third digit is typed | R2 |  | Closed, fixed (round 3) |
| MONEY-R2-05 | Minor | Amount field silently cuts pasted extra decimals ('1.234' EUR becomes 1.23) while split fields refuse the same text | R2 | 1 | Closed, fixed (round 4) |
| MONEY-R3-01 | Major | Select-all paste over an existing amount is read as an edit: IDR 1,500,000 replaced by a pasted 2,000,000 becomes Rp 2.00 | R3 |  | Closed, fixed (round 4) |
| MONEY-R3-02 | Major | Typing a dot-grouped thousand key by key keeps a 1000x smaller amount: VND 50.000 becomes ₫50, IDR 50.000 becomes Rp 50.00 | R3 |  | Closed, fixed (round 4) |
| MONEY-R3-03 | Minor | A ',' or '.' typed after a three-digit decimal comma turns TND/KWD/BHD 1.250 into 1,250 | R3 | 1 | Closed, fixed (round 5) |
| MONEY-R3-04 | Minor | Regression from the R2-02 fix: 'USD .50', 'Rs. .50' and 'EUR ,50' now read as 50, not 0.50 | R3 |  | Closed, fixed (round 4) |
| MONEY-R3-05 | Minor | A pasted text with several numbers is joined into one amount, and a multiplier suffix is dropped ('Rs 500 paid at Cafe 21' becomes ₹50,021, '2.5k' becomes ₹2.50) | R3 | 3 | **OPEN** |
| MONEY-R3-06 | Minor | TND '1,250' means 1.250 DT when typed in the amount field but 1,250 DT in split fields, the multi-payer sheet and a paste | R3 |  | Closed, fixed (round 4) |
| MONEY-R4-01 | Minor | A short dot group typed in a no-decimal currency is held as grouping: JPY '800.50' becomes ¥80,050, KRW '5.00' becomes ₩500 | R4 | 2 | **OPEN** |
| MONEY-R4-02 | Minor | TND amount field shows 1,250 DT as '1,250' but reads a pasted '1,250' as 1.250 DT | R4 |  | Closed, fixed (round 5) |
| MONEY-R4-03 | Minor | Split and payer fields strip currency words before reading: a pasted 'Rs. 50' or 'Rs.50' becomes ₹0.50 | R4 |  | Closed, fixed (round 5) |
| MONEY-R4-04 | Minor | Adjustment field saves a minus written as an en dash, in brackets or after the number as a plus | R4 | 2 | **OPEN** |
| MONEY-R5-01 | Minor | A cent, pence, percent or fraction mark after the number is dropped: '99¢' becomes $99, '50p' becomes £50 | R5 |  | Closed, fixed (round 6) |
| MONEY-R6-01 | Minor | A dot-grouped number whose last group is short is read as grouping: EUR '1.200.50' becomes €120,050, USD paste '1.200.50' $120,050 | R6 |  | **OPEN** |

#### SYNC

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| SYNC-R1-06 | Critical | Phones whose device ids were created within the same ~65 s cannot see each other in discovery (UUIDv7 prefix treated as 'self') | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-01 | Major | After syncing with a phone whose clock is more than 1 h ahead, edits on the other phone to the same fields are silent no-ops | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-02 | Major | Discovery tokens only match within one 10-minute window, so a phone with a skewed clock (even +6 min) is shown as not sharing any group | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-03 | Major | Both phones tapping Sync on each other at the same time makes both fail with 'busy: Syncing with another phone' | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-07 | Major | With more groups than the advert holds (Nearby 4 tokens, BLE/LAN 16), a shared group is often not advertised, so the nearby phone shows 'Pair' | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-08 | Major | No dataExtractionRules: Android 12+ device-to-device transfer copies the op log and device id, forking per-device counters | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-04 | Minor | A link drop right after the initiator's BYE records a complete sync as partial/connectionLost on the responder (the two phones disagree) | R1 |  | Closed, fixed (round 2) |
| SYNC-R1-05 | Minor | Host rejects a retry from the SAME phone as 'busy: Syncing with another phone' while it still holds that phone's dead (half-open) session | R1 |  | Closed, fixed (round 2) |
| SYNC-R2-01 | Minor | A phone in more groups than the advert holds (over 24 on Nearby, over 48 on BLE/LAN) still hides the shared group in some token windows, so the nearby phone shows 'Pair' | R2 |  | Closed, fixed (round 3) |
| SYNC-R2-02 | Minor | Mutual Sync where one phone's dial takes longer than the handshake timeout: the other phone is told 'busy: Syncing with another phone' | R2 |  | Closed, fixed (round 3) |
| SYNC-R3-01 | Minor | Cancel is ignored while a refused Sync waits for the other phone's slow dial, and the Sync then goes ahead anyway | R3 |  | Closed, fixed (round 4) |
| SYNC-R3-02 | Minor | A third phone that taps Sync on a phone busy dialing someone else now waits about 3 handshake timeouts (about 30 s in production) on 'Comparing' before it is told | R3 | 1 | Closed, fixed (round 5) |
| SYNC-R4-01 | Minor | Cancel while 'Connecting' over a route that hangs does nothing until the connect attempt gives up (up to 10 s) | R4 |  | Closed, fixed (round 5) |
| SYNC-R5-01 | Minor | A phone renamed while hosting keeps advertising its old name for up to 10 minutes, so its mutual Sync is refused as 'Starting its own sync with someone else' | R5 |  | Closed, fixed (round 6) |
| SYNC-R6-01 | Minor | After a rename while visible, a missed mDNS goodbye leaves the old LAN service cached, so the Nearby row keeps flipping between the old and the new name | R6 |  | **OPEN** |

#### DATA

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| DATA-R1-02 | Critical | Any exception in startup (newer or unreadable DB, I/O error, disk full on first launch) leaves the app stuck before runApp with no error screen | R1 |  | Closed, fixed (round 2) |
| DATA-R1-01 | Major | Corrupt row holding my latest op makes the next command reuse its counter and silently drop the new expense | R1 |  | Closed, fixed (round 2) |
| DATA-R1-04 | Major | hlc.last save failing after a committed insert reports the command as failed, leaves a stale snapshot, and a retry duplicates the expense | R1 |  | Closed, fixed (round 2) |
| DATA-R1-09 | Major | Search screen is O(results x ops): unsharedEntityIds getter scans the full op log once per result row | R1 |  | Closed, fixed (round 2) |
| DATA-R1-03 | Minor | user_version 0 with existing v1 tables crashes migrate (CREATE TABLE without IF NOT EXISTS) | R1 |  | Closed, fixed (round 2) |
| DATA-R1-05 | Minor | Corrupt kv profile row: re-onboarding mints a new personId, so balances in existing groups no longer count as mine | R1 |  | Closed, fixed (round 2) |
| DATA-R1-06 | Minor | Corrupt kv device row silently rotates the device id; my unshared ops stop being shown as unshared | R1 |  | Closed, fixed (round 2) |
| DATA-R1-07 | Minor | Storage failures escape Ledger commands raw instead of as LedgerException; the UI can only show generic copy | R1 |  | Closed, fixed (round 2) |
| DATA-R1-08 | Minor | Orphaned group key (app killed between keystore write and op commit in createGroup) shows forever as an untitled pending join | R1 |  | Closed, fixed (round 2) |
| DATA-R2-01 | Minor | A stale invite hint that cannot be cleared when Ledger.open runs (full disk) stops the app from starting | R2 |  | Closed, fixed (round 3) |
| DATA-R2-02 | Minor | Search 'No results' headline throws 'string is not well-formed UTF-16' when a long query has an emoji at the 40-character cut | R2 |  | Closed, fixed (round 3) |
| DATA-R3-01 | Minor | A forged peer-knowledge row already on disk hides edits made after the open once the app restarts | R3 |  | Closed, fixed (round 4) |
| DATA-R3-02 | Trivial | CSV export file name is cut at 80 UTF-16 units and can end in a lone surrogate | R3 |  | Closed, fixed (round 4) |
| DATA-R4-01 | Trivial | If the cut of a forged peer row fails at open, the next open hides edits made later in that session | R4 |  | Closed, fixed (round 5) |
| DATA-R4-02 | Trivial | CSV export of a group whose first character is longer than 80 UTF-16 units is named ".csv" | R4 |  | Closed, fixed (round 5) |
| DATA-R4-03 | Trivial | The HELLO device name is cut at 100 UTF-16 units and can end in a lone surrogate or half a cluster | R4 |  | Closed, fixed (round 5) |
| DATA-R5-01 | Trivial | mDNS, BLE and Nearby advert names are cut by code points and can split a character | R5 |  | Closed, fixed (round 6) |
| DATA-R5-02 | Trivial | A phone name made of one character longer than 100 UTF-16 units is sent in HELLO as an empty name | R5 |  | Closed, fixed (round 6) |
| DATA-R5-03 | Trivial | A group name that starts with dots and spaces exports as a hidden .csv file | R5 |  | Closed, fixed (round 6) |
| DATA-R6-02 | Minor | A profile name that shows nothing is accepted at onboarding, then no group can be created | R6 |  | **OPEN** |
| DATA-R6-01 | Trivial | A phone name that shows nothing (zero-width space, Hangul filler, braille blank) is shown as a blank name on the other phone | R6 |  | **OPEN** |

#### UIFLOW

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| UIFLOW-R1-02 | Major | No 50-member limit: Members (and New group) accept a 51st active member | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-05 | Major | After choosing multiple payers, changing the amount silently disables Save | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-07 | Major | Invite deep link opened before or during onboarding is lost | R1 | 1 | Closed, fixed (round 3) |
| UIFLOW-R1-08 | Major | Screens opened by deep link have nothing below them: Close on Invitation does nothing; after joining, Back cannot reach Home | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-09 | Major | Exported CSV is shared as a random file name, not '&lt;group&gt;.csv' | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-14 | Major | Amounts above 9,999,999.99 are silently rejected: a Rp 12,000,000 bill cannot be entered and no message is shown | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-15 | Major | With only 1:1 (direct) balances left, Home shows the empty state and hides the debt and the FAB | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-17 | Major | No per-group activity feed (SPEC 1.2 feature 10) | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-18 | Major | Renaming yourself in Settings never reaches your groups, although the prompt says 'Friends see this when you sync.' | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-19 | Major | Members screen removes a person who still owes money (SPEC 6.7 says the UI blocks it) | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-01 | Minor | The same name can be added several times, creating indistinguishable members | R1 | 1 | Closed, fixed (round 3) |
| UIFLOW-R1-03 | Minor | Member and person names have no 40-character limit in the UI or the Ledger | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-04 | Minor | Split bar reads 'Rs 0 left to split' while Save is disabled (nobody ticked, or adjustments exceed the total) | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-06 | Minor | Android back on the Activity or Sync tab closes the app instead of returning to Home | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-10 | Minor | CSV export failure is unhandled: no copy, error goes to the zone | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-11 | Minor | Settings name and Phone name prompts accept any length | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-12 | Minor | About &gt; Version is hard-coded '1.0.0 (1)' while pubspec builds 0.1.0+1 | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-13 | Minor | Settings CSV export reads a stale ledger snapshot (ref.read of a paused provider) | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-16 | Minor | Home FAB starts a new expense in an archived group | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R1-20 | Minor | Android back on a filled-in Add expense throws the draft away without asking | R1 | 1 | Closed, fixed (round 3) |
| UIFLOW-R1-21 | Minor | A 1:1 group ('Just you two') accepts a third person from its Members screen | R1 |  | Closed, fixed (round 2) |
| UIFLOW-R2-05 | Major | 50 fix commits on qa/integration carry co-author and session attribution trailers, against the owner's explicit instruction | R2 | 1 | Closed, fixed (round 4) |
| UIFLOW-R2-01 | Minor | An invite deep link opened while Add expense holds a draft throws the draft away without asking | R2 |  | Closed, fixed (round 3) |
| UIFLOW-R2-02 | Minor | Typing past the amount cap leaves a truncated amount in the field with Save enabled, so a tenth of the bill can be saved | R2 |  | Closed, fixed (round 3) |
| UIFLOW-R2-03 | Minor | Renaming yourself in Settings to the name of someone in your group makes two indistinguishable members | R2 |  | Closed, fixed (round 3) |
| UIFLOW-R2-04 | Minor | One amount cap (9,999,999.99) for every currency refuses everyday IDR/COP bills | R2 |  | Closed, fixed (round 3) |
| UIFLOW-R3-01 | Minor | Which one are you? &gt; I'm not on the list adds a second member with your name when the group already lists you | R3 |  | Closed, fixed (round 4) |
| UIFLOW-R3-02 | Trivial | A Settings rename that clashes only with a 1:1 friend is refused with 'Rahul is already in Rahul' | R3 |  | Closed, fixed (round 4) |
| UIFLOW-R4-01 | Minor | A name with an invisible mark (U+200E, U+200B, ...) gets past every duplicate-name check and is saved as an exact duplicate | R4 |  | Closed, fixed (round 5) |
| UIFLOW-R4-02 | Trivial | Android back on the claim screen's 'Is that you?' question opens the 'Your name in &lt;group&gt;' prompt | R4 |  | Closed, fixed (round 5) |
| UIFLOW-R5-01 | Minor | A name ending in a soft hyphen, ZWJ, variation selector or invisible operator gets past the duplicate-name check and shows as a second 'Rahul' | R5 |  | Closed, fixed (round 6) |
| UIFLOW-R6-01 | Minor | A Hangul filler or braille blank in place of the space gets 'Rahul&lt;filler&gt;Kumar' past the duplicate check, and it shows as a second 'Rahul Kumar' | R6 |  | **OPEN** |

#### VISUAL

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| VISUAL-R1-01 | Major | Expense/payment detail total is clipped instead of scaled down (₹1,20,000.50 on a 360 dp phone at 1.0x; a ₹200 payment at 2.0x) | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-02 | Major | Home hero 'Coming to you' / 'You owe' amounts are silently clipped at large text | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-03 | Major | Suggested-payment row (TransferRow) overflows horizontally at 320 dp, 1.3x on Group and Settle up | R1 | 1 | Closed, fixed (round 3) |
| VISUAL-R1-04 | Major | Settle up 'What changes' table clips amounts in its fixed 96 dp columns (−KD1,250.750 at 1.3x) | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-05 | Major | Add/Edit expense app bar overflows when the group name is long (60 chars allowed; 39 chars enough at 320 dp 1.3x) | R1 | 1 | Closed, fixed (round 3) |
| VISUAL-R1-09 | Major | Home sync card is a focusable tap target with no semantics label (TalkBack announces nothing) | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-06 | Minor | Expense row subline ellipsizes the payer amount ('Sam paid ¥5,…', 'You paid ₹1,20,…') on small phones and at 1.3x | R1 | 1 | Closed, fixed (round 3) |
| VISUAL-R1-07 | Minor | Group app bar subtitle 'N people, ₹X spent' is ellipsized at 2.0x, hiding the group total | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-08 | Minor | BalanceTrailing amount has no fit strategy: Activity rows clip Money.maxMinor amounts at 320 dp 2.0x | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-10 | Minor | TextLink is a 32 dp tap target ('Share link', 'Pay part of it', 'Look again', 'See all', onboarding/claim links) | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-11 | Minor | Detail screen shows 'not involved ₹0' (and reads '0.00 INR') for an expense or payment you are not part of | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-12 | Minor | Search 'no results' empty state does not scroll: overflows the bottom and hides 'Clear search' on small phones / large text | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-13 | Minor | Raw CircularProgressIndicators keep spinning under 'Remove animations' (the kit's _Spinner stops) | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-14 | Minor | Launch screen is the stock Flutter template (white / black) and does not match the stone background or the in-app theme | R1 |  | Closed, fixed (round 2) |
| VISUAL-R1-15 | Trivial | SPEC still names Atkinson Hyperlegible Next; the app bundles Familjen Grotesk (DESIGN.md) | R1 |  | Closed, fixed (round 2) |
| VISUAL-R2-02 | Major | Settle up 'How you paid' clips the selected 'Cash' segment to 'Cas' on a 360 dp phone at default text size | R2 |  | Closed, fixed (round 3) |
| VISUAL-R2-01 | Minor | Expense row direction word is broken mid-word ('you borrowe / d') since the trailing block was capped at 32% of the width | R2 |  | Closed, fixed (round 3) |
| VISUAL-R2-03 | Minor | Group type segments break mid-word ('Hom/e', 'Cou/ple', 'Othe/r') on New group and Edit group at large text | R2 |  | Closed, fixed (round 3) |
| VISUAL-R2-04 | Minor | Group 'All balances' and person 'Add expense' buttons break mid-word at 2.0x | R2 |  | Closed, fixed (round 3) |
| VISUAL-R2-05 | Minor | Sync session progress bar is an indeterminate LinearProgressIndicator that keeps animating under 'Remove animations' | R2 |  | Closed, fixed (round 3) |
| VISUAL-R2-06 | Minor | Search 'no results' headline cuts a long query mid-emoji, which throws 'string is not well-formed UTF-16' during layout | R2 |  | Closed, fixed (round 3) |
| VISUAL-R2-07 | Trivial | Group app bar fallback 'KD999,999.999 spent' is still ellipsized at 320 dp, 1.3x and 2.0x | R2 |  | Closed, fixed (round 3) |
| VISUAL-R3-01 | Minor | Activity rows squeeze the sentence below one word, to 0 dp, and overflow with huge amounts at 320 dp between 1.3x and 1.59x | R3 |  | Closed, fixed (round 4) |
| VISUAL-R4-02 | Major | Expense amount field silently hides part of a realistic amount (₹1,20,000.50 at 320 dp 1.0x, 360 dp 1.3x) | R4 |  | Closed, fixed (round 5) |
| VISUAL-R4-01 | Minor | Sync screen tether overflows its row at 320-340 dp between 1.4x and 1.59x text (stock Android 1.5x step included) | R4 |  | Closed, fixed (round 5) |
| VISUAL-R4-03 | Minor | Expense editor split rows break the share amount over two lines, and the 112 dp share field hides digits | R4 | 1 | Closed, fixed (round 6) |
| VISUAL-R4-04 | Minor | Expense detail 'Who paid / Who owes' rows squeeze the name below one word, to 0 dp, and overflow with huge amounts | R4 |  | Closed, fixed (round 5) |
| VISUAL-R4-05 | Minor | Home and Person balance rows squeeze the group name below one word at 320-360 dp, 1.3x to 1.59x | R4 |  | Closed, fixed (round 5) |
| VISUAL-R5-01 | Major | Keyboard closes mid-entry when a split share row switches between beside and stacked while typing | R5 |  | Closed, fixed (round 6) |
| VISUAL-R5-02 | Major | Equal-split rows (MemberSplitRow) break the share amount, squeeze names to 0-11 dp and overflow with a realistic ₹1,20,000.50 | R5 |  | Closed, fixed (round 6) |
| VISUAL-R6-01 | Minor | Multi-payer sheet squeezes 'Split the rest equally' beside 'Done': the label takes 2-5 lines and 'equally' breaks mid-word at 320 dp 2.0x | R6 |  | **OPEN** |

#### SECURITY

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| SECURITY-R1-01 | Major | Op forged with this phone's own device id poisons its counter; later local ops never sync | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-02 | Major | Remote ops bypass SPEC 5.16 text limits; gzip-compressible huge strings are stored | R1 | 1 | Closed, fixed (round 3) |
| SECURITY-R1-05 | Major | Ledger does not enforce the SPEC 5.16 length and member-count limits | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-07 | Major | No android:dataExtractionRules: Android 12+ device-to-device transfer still copies the app data | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-08 | Major | Share link sends the group key without the SPEC 8.6 warning | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-11 | Major | Secure storage uses defaults (resetOnError: true): a Keystore failure silently wipes every group key | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-03 | Minor | Ops stamped far in the future are accepted and win last-writer-wins permanently | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-04 | Minor | An op in one group can hide an expense of another group by reusing its id with an older HLC | R1 | 1 | Closed, fixed (round 3) |
| SECURITY-R1-06 | Minor | Names and descriptions accept control, zero-width and bidi-override characters | R1 | 1 | Closed, fixed (round 3) |
| SECURITY-R1-09 | Minor | The invite QR (the group key) is captured in screenshots and the recents thumbnail | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-10 | Minor | An unauthenticated connection holds the single session slot for the whole handshake timeout | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-12 | Minor | A permanent device-id prefix is broadcast in mDNS, Nearby and BLE, so phones can be tracked despite token rotation | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-13 | Minor | Bundled ML Kit barcode scanning sends usage telemetry to Google, which is not disclosed | R1 |  | Closed, fixed (round 2) |
| SECURITY-R1-14 | Minor | settleup://sync deep links dial any host, including public internet addresses | R1 |  | Closed, fixed (round 2) |
| SECURITY-R2-02 | Major | After a Keystore key loss, resetOnError:false makes secure storage permanently unusable, so the advertised 'scan the invite again' recovery never works | R2 |  | Closed, fixed (round 3) |
| SECURITY-R2-01 | Minor | A forged version vector marks this phone's later changes as shared although no phone has them | R2 |  | Closed, fixed (round 3) |
| SECURITY-R2-03 | Minor | A stranger reconnecting in a tight loop evicts friends' pending handshakes and locks them out of the host | R2 |  | Closed, fixed (round 3) |
| SECURITY-R2-04 | Trivial | Peer device names (HELLO, adverts, connect links) keep bidi override characters | R2 |  | Closed, fixed (round 3) |
| SECURITY-R3-01 | Major | A peer op with a wrong-typed known field hides a whole group, a member or an expense on every phone, and the op is accepted | R3 |  | Closed, fixed (round 4) |
| SECURITY-R3-02 | Trivial | Names made only of unassigned default-ignorable code points are still accepted locally and from peers | R3 |  | Closed, fixed (round 4) |
| SECURITY-R4-01 | Major | A peer's expense dated in the first day of the DateTime range breaks the group screen and expense editor on every phone outside UTC | R4 |  | Closed, fixed (round 5) |
| SECURITY-R4-02 | Minor | Remote currency codes are not held to the ISO shape the local Ledger enforces | R4 |  | Closed, fixed (round 5) |
| SECURITY-R5-01 | Minor | Expense and payment editors cannot open the date picker for an expense dated before 2000 or after next year, though peers may send one and a phone with a reset clock writes one | R5 |  | Closed, fixed (round 6) |
| SECURITY-R6-01 | Minor | On a phone whose clock was reset to 1970 the editors' date picker ends at 1971-12-31, so a new expense can never be given the real date | R6 |  | **OPEN** |

#### PLATFORM

| ID | Severity | Title | Found | Reopened | Final status |
|---|---|---|---:|---:|---|
| PLATFORM-R1-02 | Blocker | The app never requests runtime permissions, so Bluetooth (BLE) and Nearby sync are never available on any Android phone | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-01 | Critical | main() awaits bootstrap() with no error handling: any startup failure crashes or blanks the app on launch, with no recovery | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-06 | Critical | The release build is always signed with the Android debug key; there is no key.properties signing config | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-03 | Major | No dataExtractionRules: device-to-device transfer to a new phone (Android 12+) copies the op log with the same device id and orphans the group keys | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-05 | Major | The launcher icon is the stock Flutter icon; no adaptive or monochrome icon; the splash screen is unbranded | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-10 | Major | No privacy policy or store listing; the policy must also disclose ML Kit usage metrics from mobile_scanner | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-11 | Major | No recovery path when Bluetooth/Nearby permission is permanently denied or the radio is off (no 'Open settings' / 'Turn on Bluetooth' action) | R1 | 1 | Closed, fixed (round 3) |
| PLATFORM-R1-04 | Minor | Version is 0.1.0+1, not the production 1.0.0+N | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-07 | Minor | Flutter template TODOs remain in the Android build, and the applicationId is still the codename | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-08 | Minor | README is a single heading: no run, build, test or release instructions | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R1-09 | Minor | Nearby reports 'ready' on phones without Google Play services | R1 |  | Closed, fixed (round 2) |
| PLATFORM-R2-01 | Major | On API 26-30 the location switch being off is shown as 'Bluetooth is off', with a button that opens Bluetooth settings | R2 |  | Closed, fixed (round 3) |
| PLATFORM-R2-02 | Minor | The debug-key fallback warning is invisible on the documented build path (flutter build runs Gradle with -q) | R2 |  | Closed, fixed (round 3) |
| PLATFORM-R2-03 | Trivial | The privacy policy says nearby devices see a device id prefix, but only a rotating advert id is advertised | R2 |  | Closed, fixed (round 3) |
| PLATFORM-R3-01 | Minor | 'Make this phone visible' with the location switch off (API 26-30, no Wi-Fi) fails with 'Bluetooth or Wi-Fi is off' while Bluetooth is on | R3 |  | Closed, fixed (round 4) |
| PLATFORM-R3-02 | Trivial | The privacy policy does not say that the visible-phone QR carries the stable device id and local IP address | R3 |  | Closed, fixed (round 4) |

## 6. Device-only checks for the owner's test phone

None of these were run: no emulator or phone was available. They are merged
and deduplicated from every area's device notes. Tick each one and note the
phone, Android version and result. Radio steps in detail: [../QA.md](../QA.md).
Many need two phones (marked **2P**).

### 6.1 Install, signing, startup

- [ ] Build the final APK with a real `android/key.properties` and confirm the
  debug-key warning is gone and the APK is release-signed (PLATFORM-R1-06,
  PLATFORM-R2-02). The local build here is debug-signed.
- [ ] 0.1.0 tester installs: 1.0.0 has a new app id and key, so it installs as
  a second "Settle Up". Follow the release-notes install note (sync, rejoin
  by invite, uninstall 0.1.0) and check `settleup://` links open the 1.0.0 app.
- [ ] Update 1.0.0+2 to a later 1.0.0+N build over existing data: the
  database opens unchanged, HLC and counters continue, group keys still
  decrypt.
- [ ] Cold start the release APK on API 26 and on API 36: nothing that the
  plugins load by reflection was stripped by R8 (nearby_connections/GMS,
  bluetooth_low_energy, mobile_scanner/ML Kit, flutter_secure_storage,
  bonsoir, cryptography_flutter, path_provider over jni).
- [ ] Startup error screen: install over a newer-schema database (`adb install
  -d`) or a corrupt `settle_up.db`; the error screen shows and Try again
  reopens the file once it is fixed (DATA-R1-02, PLATFORM-R1-01).
- [ ] Cold-start time with a 20k-op log on a low-end phone in release (host:
  858 ms against a 2 s budget; open and replay run before `runApp`).
- [ ] Full disk: the app opens and shows balances; adding an expense shows the
  storage error and works after space is freed; first launch on a full disk
  (DATA-R1-02/04/07).
- [ ] Kill the app (swipe away or `adb shell am kill`) mid-createGroup and
  mid-sync (large applyRemote) on both phones; relaunch: no ghost group, no
  half-applied batch, no duplicates on resync, unshared counts correct
  (DATA-R1-08). **2P**
- [ ] Launcher icon, Android 13+ themed icon, recents icon; launch screen on
  API 26-30 (stone with the tether, light and night) and the API 31+ splash;
  pick Dark in Settings with the system light, then cold start: the splash is
  dark (PLATFORM-R1-05, VISUAL-R1-14).
- [ ] Theme "Match system" follows the system dark-mode toggle live, with no
  launch flash.
- [ ] iOS (if built): Local Network, Bluetooth and camera prompts and copy;
  Nearby hidden.

### 6.2 Permissions and radio states

- [ ] Fresh install on API 29/30, 31/32 and 33+: the Sync tab shows the
  location / Nearby devices / Nearby Wi-Fi dialogs, and BLE-only discovery and
  hosting work after granting (PLATFORM-R1-02).
- [ ] Deny twice ("Don't allow"): "Open settings" stays after the dialog
  closes, after a tab change and after returning from settings without a
  grant, and goes away once granted (PLATFORM-R1-11).
- [ ] Android 12 "Approximate location" on API 31/32: copy and flow make sense
  (permission_handler reports COARSE-only as denied).
- [ ] API 31+ with BLUETOOTH_SCAN/NEARBY_WIFI_DEVICES `neverForLocation`:
  Nearby discovery still finds peers. **2P**
- [ ] Android 8-11, Bluetooth on, Location off: the row reads "Location is
  off", "Turn on location" opens the location page, and "Make this phone
  visible" with Wi-Fi off gives the "Location is off ..." snack
  (PLATFORM-R2-01, PLATFORM-R3-01). Check BLE advertising works with
  location off.
- [ ] Android 12/12L with location and Wi-Fi off: "Make this phone visible"
  goes ahead over BLE with Nearby skipped; check whether Nearby discovery
  really needs the location switch.
- [ ] Phone without Google Play services (Huawei, Fire): Nearby reports
  unsupported after the first failure, no GMS prompt loop, BLE and LAN still
  sync (PLATFORM-R1-09). **2P**
- [ ] Turn Bluetooth and Wi-Fi off and on while the Sync tab is open.

### 6.3 Sync on real radios (**2P** unless noted)

- [ ] LAN on a router and on an Android hotspot: mDNS discovery, hotspot
  gateway probe, invite `h=` host when the phone has cellular, VPN and hotspot
  interfaces at once (QA.md 2).
- [ ] BLE GATT at 16 KiB frames: throughput for 2,000+ ops, and the
  disconnect after BYE records a complete sync on both phones (SYNC-R1-04).
- [ ] Nearby Connections: latency; the v2 endpoint name (24 tokens, advert
  id, window tag, trailing `+`, up to 131 bytes) is accepted by
  `startAdvertising` and survives discovery (SYNC-R1-07, SYNC-R2-01).
- [ ] Android NSD/bonsoir accepts the 4-key TXT record (`t`, `t1`-`t3`, up to
  243 bytes each, about 1,000 bytes in all).
- [ ] With many groups (over 4 on Nearby, over 16 on BLE/LAN) the shared group
  still shows "Sync", not "Pair", across several 10-minute windows.
- [ ] Re-advertising (each 10-minute window, and after a rename): does the
  Nearby endpointId change? If yes, check the Nearby row is not duplicated
  and that Sync never dials the dead old endpoint.
- [ ] Rename the phone in Settings while visible: the other phone shows the
  new name within seconds over LAN, Nearby and BLE (SYNC-R5-01). Record
  whether the old name flips back (open SYNC-R6-01). Rename during a running
  Nearby sync: the connection is not dropped.
- [ ] Both phones tap Sync on each other at the same time, over Nearby and
  BLE (SYNC-R1-03); and with one phone's LAN route hanging behind Wi-Fi client
  isolation before Nearby connects (SYNC-R2-02).
- [ ] Cancel on B while it waits for A's slow dial: "Sync cancelled." within
  a second, and the sync does not go ahead (SYNC-R3-01). Cancel while
  "Connecting" over a hanging LAN route or a pending Nearby request: how long
  the screen stays, and the abandoned Nearby connection is torn down without
  leaving an incoming request on the other phone (SYNC-R4-01).
- [ ] Third phone C taps Sync on A while A dials B slowly: C is told within
  about 10 s; repeat with two same-model phones on the default device name;
  a mutual Sync between same-model phones still completes (SYNC-R3-02).
  **3 phones**
- [ ] Two phones onboarded within the same minute see each other on every
  transport (SYNC-R1-06).
- [ ] Clock skew: set one phone +2 h and another -1 day (auto time off). Sync
  shows "Sync", not "Pair" (SYNC-R1-02); Settings says "This phone's clock
  looks wrong"; edits after the sync take effect on both (SYNC-R1-01).
- [ ] Wi-Fi lost mid-sync (half-open TCP): how long the host stays busy, and
  the retry from the same phone is accepted and resumes without duplicates
  (SYNC-R1-05).
- [ ] Hosting expiry (5 min) and token rotation across a real 10-minute
  boundary while advertising on all radios.
- [ ] Both phones record the same cash payment offline, then sync: the
  balance flips and the possible-duplicate hint shows (MONEY-R1-06).
- [ ] How cut names look on the peer: a long Devanagari phone name cut to the
  63-byte mDNS label, flag or conjunct cuts in Nearby/BLE names, and a name
  with U+FFFD in the Sync screen and history (DATA-R4-03, DATA-R5-01).

### 6.4 Security and privacy

- [ ] Stranger phone without the key: Nearby auto-accepts the endpoint, the
  session layer refuses it, no crash, no stuck session. **2P**
- [ ] A stranger flooding TCP connects from one IP (with and without HELLOs)
  while a friend syncs: the friend still gets in (SECURITY-R2-03). **3 phones**
- [ ] Capture TCP 52741 on a hotspot (Wireshark/PCAPdroid): only HELLO, AUTH
  and ERROR are plain; no group id or name in clear.
- [ ] mDNS browser and nRF Connect: TXT/INFO/endpoint names show rotating
  tokens and a rotating advert id only; no group id, no key, no stable device
  id prefix (SECURITY-R1-12).
- [ ] Release logcat during invite, join and sync: no group key, invite link
  or payload printed.
- [ ] Invite QR: screenshots and screen recordings are black, the recents
  thumbnail is blank while it shows, and both work again after the 2-minute
  auto-hide or on leaving the screen (SECURITY-R1-09).
- [ ] Scan a QR with mobile data on: nothing goes to
  `firebaselogging-pa.googleapis.com` (SECURITY-R1-13).
- [ ] Open `settleup://sync?h=203.0.113.7:52741` from a browser before and
  after onboarding: no connection attempt. Note: loopback is still dialed by
  design (SECURITY-R1-14).
- [ ] Android 12+ device-to-device transfer (Pixel "Copy apps & data",
  Samsung Smart Switch) and `adb shell bmgr`: `settle_up.db` and the
  secure-storage prefs are not copied; the new phone starts fresh with a new
  device id (SYNC-R1-08, SECURITY-R1-07, PLATFORM-R1-03).
- [ ] Keystore disruption (remove or change the screen lock, OEM reset, or
  delete the alias in a debug build): flutter_secure_storage reports the key
  mismatch, the app shows the recovery, and re-scanning an invite stores the
  key again; creating a group works (SECURITY-R1-11, SECURITY-R2-02). Also
  check keys survive an app update and an OS update.

### 6.5 Amount entry on real keyboards

- [ ] Gboard and Samsung keyboards, `numberWithOptions(decimal: true)`, in
  de_DE, fr_FR and hi_IN: which separators the keypad offers; '12,50' is
  12.50 in the amount field and in the split fields; typing lakh and
  comma-grouped amounts (MONEY-R1-02/04, MONEY-R2-01, MONEY-R2-04).
- [ ] Typing ',' and '.' in TND, KWD, VND and IDR on those keypads
  (MONEY-R3-02, MONEY-R3-03).
- [ ] Arabic/Persian keyboards that type Eastern Arabic digits: can an amount
  be entered at all?
- [ ] Select-all paste over an existing amount from the real text toolbar
  (MONEY-R2-05, MONEY-R3-01).
- [ ] Amount near the cap (UIFLOW-R2-02) and the 40-character counters on the
  name prompts.
- [ ] Non-English system locale: amounts still display in the app's format
  (MoneyFormat uses en/en_IN).

### 6.6 Navigation, deep links, sharing, camera

- [ ] `settleup://join` and `settleup://sync` from another app and from the
  camera app's QR scanner: cold start on a fresh install and on an onboarded
  install, and warm (singleTop) (UIFLOW-R1-07, UIFLOW-R1-08).
- [ ] An invite link tapped in a chat app while Add expense, Settle up or New
  group holds a draft: the invitation opens over the draft and Close returns
  to it (UIFLOW-R2-01).
- [ ] A `settleup://sync` link while a sync session is running: Scan opens
  over the session and the busy copy is sensible.
- [ ] Back and predictive back: Activity and Sync tabs return to Home; the
  invitation opened by a link; Add expense with a draft asks first; Settle up
  during the bubble animation; Join and Claim screens.
- [ ] CSV share sheet: file shows as "Goa trip.csv" and "गोवा ट्रिप.csv" in
  Gmail, Drive and WhatsApp; Excel for Android, Google Sheets and WPS open it
  with correct non-ASCII text (UTF-8 BOM); formula-like cells stay inert; the
  behaviour when no app handles ACTION_SEND (MONEY-R1-09, UIFLOW-R1-09).
- [ ] Invite and Scan with the real camera and real hosting; the 2:00 QR
  hide timer.
- [ ] Haptics: none with Settings > Vibration off; selection, medium and heavy
  feedback feel right.

### 6.7 Layout, keyboard, accessibility, motion

- [ ] A 320-360 dp phone with Display size "Largest" and font size 1.3x,
  1.5x and 2.0x (OEM font rendering): detail totals, Home hero, suggested
  payments on Group and Settle up, "What changes", the expense editor with a
  60-character group name, expense and activity rows, balance rows, the Sync
  tether at 1.5x, "Cash" at 360 dp 1.0x (VISUAL-R1-01 to R1-08, VISUAL-R2-02,
  VISUAL-R4-01, VISUAL-R4-05).
- [ ] Edit a ₹1,20,000.50 expense at 320-360 dp, 1.0x and 1.3x: the amount
  field shows the whole amount, focused and unfocused (VISUAL-R4-02).
- [ ] Android 14 nonlinear font scaling (130%-200%) on split rows.
- [ ] Keyboard open (gesture and 3-button nav) on Add expense, Search and the
  pay-part sheet on a short phone: Save bar, split summary, exact/percent
  inputs and Done stay visible; Search no-results stays scrollable.
- [ ] Typing a share in exact, percent and adjustment rows and in the
  multi-payer sheet at 320-360 dp, 1.0x and 1.3x: the keyboard stays open when
  a row switches between beside and stacked (VISUAL-R5-01).
- [ ] TalkBack walk-through of Home, Group, Settle up, Add expense and Sync:
  focus order, merged row labels, hero sentence, the Sync card announced once
  (VISUAL-R1-09), amounts and direction words in "What changes" and expense
  rows for a multi-currency pair, the selected group-type chip and payment
  method.
- [ ] "Remove animations" (developer and accessibility settings) during a real
  sync: spinners, the sync progress bar, the settle dot and the tether are
  still (VISUAL-R1-13, VISUAL-R2-05).
- [ ] Android 15+ edge to edge: status and gesture bars over the stone
  background; FAB and Save bar above the gesture pill.
- [ ] Lagoon and Kiln direction colours in sunlight and on AMOLED dark.

### 6.8 Dates and time zones (release build, asserts stripped)

- [ ] Edit an expense dated 1970 and one dated 2090: the date picker opens on
  that date (SECURITY-R5-01).
- [ ] Set the phone clock back to 1970 (auto time off) and open Add expense:
  record the range the picker offers (open SECURITY-R6-01).
- [ ] Time zone Asia/Kolkata, then Pacific/Kiritimati: a group holding
  expenses dated 1900-01-01 UTC and 9999-12-31 UTC renders (SECURITY-R4-01).

## 7. Residual risks

### 7.1 Product

1. **Radios are verified only on the host.** The engine, protocol and LAN
   transport ran for real over 127.0.0.1; Nearby and BLE were tested through
   their Dart layers only, without the real platform plugins. Throughput, MTU, advert
   size limits, endpoint id behaviour and OEM radio stacks are unproven until
   section 6.3 is done. Highest residual risk.
2. **Permissions and OEM behaviour** (section 6.2) are unit-tested against a
   model of permission_handler; the order of results and resume events on a
   real device is not.
3. **Keystore** loss and recovery are tested against a fake of
   flutter_secure_storage 11.2.0 whose error strings were matched to the
   plugin source. A wrong match on a real OEM would show up as groups that work
   locally but cannot sync.
4. **Amount parsing heuristics.** MONEY has 26 findings, 17 of them from
   rounds 2 to 6, nearly all in free-text parsing of typed and pasted
   amounts; 4 are still open. The
   parser is a growing set of rules, and each fix so far exposed a neighbour.
   Real keyboards may send edit sequences the harness does not (6.5). A
   simpler policy (refuse anything that is not a plain number in the
   currency's own format) would cut this risk more than further rules.
5. **Invisible and look-alike characters in names** (UIFLOW-R6-01,
   DATA-R6-01/02 open). Same pattern: deny-lists of code points.
6. **R8 at runtime.** The release build succeeds with R8 and keep rules, but
   reflection-loaded plugin classes can only be confirmed on a phone (6.1).
7. **Release APK size** is 108 MB for all ABIs; prefer
   `--split-per-abi` or an app bundle for distribution (README "Build").
8. **iOS** was not built or tested.

### 7.2 Process

1. **`dev` does not have the fixes yet** (section 1). Exit criterion 1 says a
   finding closes when its fix is merged into `dev` and re-verified; here the
   fixes were verified on `qa/integration`. Merge before release and re-run the
   suite on `dev`.
2. **Commit history.** UIFLOW-R2-05 is closed by prevention:
   `tool/git-hooks/commit-msg` rejects co-author and session attribution trailers,
   `tool/check_commit_messages.sh` checks a range, and
   `tool/squash_merge.sh` brings a branch into `dev` without them. But 182
   older commit messages on `qa/integration` still carry
   those trailers, and history is not rewritten
   (no force pushes). A plain `git merge` of this branch into `dev` would carry
   them over, against the owner's instruction. Use `tool/squash_merge.sh` and
   run `tool/check_commit_messages.sh` on the result.
3. **Device pass not run.** Section 6 is entirely outstanding.

## 8. Sign-off

| Item | Status |
|---|---|
| Open findings | **10** (0 blocker, 0 critical, 0 major, 9 minor, 1 trivial) |
| Analyze | Clean |
| Tests | 2,463 total, 2,447 passed, 16 skipped (open repros), 0 failed |
| Release build | Builds with R8; debug-signed here (no key.properties) |
| Device checks | 0 of section 6 run (no device) |
| Report clean | **No** |
| Recommendation | **No-go** for production until round 7 closes the 10 open findings, the fixes are squash-merged into `dev`, the APK is built with the release key and the device pass in section 6 passes |
