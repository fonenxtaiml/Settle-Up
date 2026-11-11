# Settle Up 1.0.0: QA report

Owner: QA lead. Branch: `qa/integration` at the commit that adds this
revision (parent `87c23be`). Baseline: `dev` at `854df42`. Rounds 1 to 21.
Date: 2026-11-11. Plan: [TEST-PLAN.md](TEST-PLAN.md). Manual radio
checklist: [../QA.md](../QA.md).

## 1. Verdict

**The report is clean. All 196 findings raised in rounds 1 to 21 are closed,
fixed and re-verified by QA. Zero findings are open, of any severity.**
`flutter analyze` reports no issues and the full suite is green
(3,254 tests, 3,254 passed, 0 skipped, 0 failed). The release
build succeeds with R8.

**Release recommendation: GO for a 1.0.0 release candidate, and GO for the
Play production release once the three conditions below are met.** The host
can show nothing more: what remains is a merge, the release key and the
device pass, none of which this environment can do.

1. **Bring rounds 7 to 21 into `dev`.** `origin/dev` is `319f2f8` (PR #12,
   the squash merge of rounds 1 to 6). `qa/integration` is 183 commits ahead
   of it and holds the 41 fixes verified since round 6. Squash merge it into
   `dev` with `tool/squash_merge.sh` (7.2), re-run `flutter analyze` and
   `flutter test -j 2` on `dev`, and build the release from `dev`/`main`, not
   from this branch. TEST-PLAN exit criterion 1 counts a fix once it is on
   `dev`; until this merge, the 41 later fixes are verified only on
   `qa/integration`.
2. **Release signing.** No `android/key.properties` exists on this host, so
   the local release build is signed with the debug key (the build prints the
   PLATFORM-R2-02 warning). The APK for the owner's phone and for Play must be
   built with the real upload key (README "Release signing").
3. **The device pass in section 6.** No emulator or phone was available.
   Radios, permissions, real keyboards (IME composing), real fonts, the
   Keystore, deep-link intents, TalkBack and R8 at runtime are verified only
   by static review and host tests. Section 6.0 lists the checks that should
   pass before a production release; the rest can follow as a tester build
   is used.

One caveat on "clean": the last full seven-area sweep (round 15) was not
clean; it found 8 findings. Rounds 17 to 21 re-verified those fixes and
probed their neighbours, finding 6, 3, 1, 0 and 0 new findings, and round 21
ended with nothing open. A full sweep has not been re-run on the final
commit (7.2). The late findings were all minor or trivial edge cases in
names, notes and hostile peer data; the last major closed in round 12.

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
| Not available | Radios (BLE, Nearby, Wi-Fi Direct/hotspot), Android Keystore, ML Kit camera, IME, intents, device fonts (Noto fallbacks), AOT timing |

## 3. Test plan summary

Seven QA areas, each with one owner and its own tests under `test/qa/<area>/`
(full charters in TEST-PLAN.md section 6):

| Area | Charter |
|---|---|
| MONEY | Split methods, rounding, balances, simplify, settle up, multi-currency, multi-payer, CSV, and amount parsing in every input (typing, paste, locales, separators, signs) |
| SYNC | Convergence through the real engine, adversarial and interrupted sessions, discovery tokens, clock skew, mutual and third-party Sync, cancel, invites, LAN loopback, rename and sighting caches, scale |
| DATA | Durability across restarts, failed and partial writes, corrupt rows, schema migrations, startup failures, performance (20k ops, pathological peer names), names and CSV file names |
| UIFLOW | Onboarding, groups, members, expenses, settle up, notes, activity, search, settings, deep links, back navigation, concurrent edits, validation copy |
| VISUAL | Layout matrix (320/360/411 dp x 1.0-2.0x x light/dark), design rules, money format, semantics and TalkBack actions, tap targets, the date picker, reduce motion, empty states |
| SECURITY | Crypto, op validation, engine abuse, input limits, key storage and Keystore loss, manifest, invite QR, dates and currencies from peers, discovery floods and crafted links |
| PLATFORM | Startup, permissions and radio states, release readiness (version, signing, icon, R8, docs), name normalisation (NameText), commit-message policy |

Workflow (TEST-PLAN.md section 8): QA files findings and writes a failing
repro; a separate pool of senior engineers fixes each one on a `fix/*` branch
with a regression test; QA merges and re-verifies; a finding closes only on QA
re-verification. Rounds 1 and 15 were full sweeps of all seven areas; rounds
2 to 6, 8 to 14 and 17 to 21 re-verified the previous fixes and probed their
neighbours; rounds 7 and 16 were engineer fix rounds with no QA verdicts.
Repros of open findings stayed in the suite as `skip:` tests until the fix
flipped them on; none is left.

Severity scale: TEST-PLAN.md section 4 (blocker, critical, major, minor,
trivial).

## 4. Metrics

### 4.1 Final run (this commit's parent, `87c23be`)

| Check | Result |
|---|---|
| `flutter analyze` | **No issues found** (infos included) |
| `flutter test -j 2` (full suite) | **3,254 tests: 3,254 passed, 0 skipped, 0 failed** (23 min 9 s on the shared host) |
| Of which `test/qa/**` | 1,603 tests: 1,603 passed, 0 skipped |
| `flutter build apk --release` | **Built** `app-release.apk` (108.7 MB, all ABIs) in about 1 min 10 s, R8 on, `mapping.txt` produced. `aapt2`: package `app.settleup.settleup`, label "Settle Up", versionCode 2, versionName 1.0.0, minSdk 26, targetSdk 36, compileSdk 37. `apksigner`: signed with the **Android Debug** certificate because `android/key.properties` is absent (the PLATFORM-R2-02 warning was printed). Build check only; the APK was deleted with `build/` and not published or handed out. |
| Commit messages | `tool/check_commit_messages.sh origin/main..HEAD`: 618 commits, all clean (no co-author or session trailers, every commit authored by sushil3125 or fonenxtaiml) |

### 4.2 Tests

| | Count |
|---|---:|
| Baseline suite at `854df42` | 866 |
| Suite at the end of round 6 | 2,463 |
| Final suite | 3,254 |
| Added by QA (`test/qa/**`) | **1,603** (data 173, money 193, platform 270, security 223, sync 229, uiflow 296, visual 219) |
| Added by the fix engineers (regression tests outside `test/qa`) | 785 |
| Skipped | 0 (no open findings, so no skipped repros) |

### 4.3 Findings by area and severity (all rounds)

| Area | Blocker | Critical | Major | Minor | Trivial | Total | Open |
|---|---:|---:|---:|---:|---:|---:|---:|
| MONEY | 0 | 1 | 10 | 15 | 0 | 26 | 0 |
| SYNC | 0 | 1 | 5 | 10 | 0 | 16 | 0 |
| DATA | 0 | 1 | 3 | 13 | 8 | 25 | 0 |
| UIFLOW | 0 | 0 | 11 | 28 | 2 | 41 | 0 |
| VISUAL | 0 | 0 | 12 | 28 | 2 | 42 | 0 |
| SECURITY | 0 | 0 | 9 | 16 | 3 | 28 | 0 |
| PLATFORM | 1 | 2 | 5 | 8 | 2 | 18 | 0 |
| **All** | **1** | **5** | **55** | **118** | **17** | **196** | **0** |

Closed: 196, all **closed, fixed** (re-verified by QA). Closed as not a
defect: 0. Open: 0. Reopen events: 26 on 22 distinct findings (a fix that
did not hold in re-verification is reopened, not duplicated); the last
reopen was UIFLOW-R19-01 in round 20, closed in round 21.

### 4.4 Findings by area and round

| Area | Round 1 | Rounds 2-6 | Rounds 8-14 | Round 15 sweep | Rounds 17-21 | Total |
|---|---:|---:|---:|---:|---:|---:|
| MONEY | 9 | 17 | 0 | 0 | 0 | 26 |
| SYNC | 8 | 7 | 1 | 0 | 0 | 16 |
| DATA | 9 | 12 | 1 | 1 | 2 | 25 |
| UIFLOW | 21 | 11 | 2 | 3 | 4 | 41 |
| VISUAL | 15 | 16 | 9 | 1 | 1 | 42 |
| SECURITY | 14 | 10 | 0 | 2 | 2 | 28 |
| PLATFORM | 11 | 5 | 0 | 1 | 1 | 18 |
| **All** | **87** | **78** | **13** | **8** | **10** | **196** |

By severity, the 31 findings raised after round 6 were 2 major
(VISUAL-R9-01, VISUAL-R11-01), 28 minor and 1 trivial (SECURITY-R17-02).

### 4.5 Rounds

| Round | Kind | New findings | Re-verified and closed | Reopened | Open at end of round |
|---|---|---:|---:|---:|---:|
| 1 | Full sweep | 87 | 0 | 0 | 87 |
| 2 | Re-verify | 28 | 77 | 10 | 38 |
| 3 | Re-verify | 17 | 36 | 2 | 19 |
| 4 | Re-verify | 17 | 16 | 3 | 20 |
| 5 | Re-verify | 9 | 16 | 4 | 13 |
| 6 | Re-verify | 7 | 10 | 3 | 10 |
| 7 | Fix round | - | - | - | 10 |
| 8 | Re-verify | 5 | 10 | 0 | 5 |
| 9 | Re-verify | 1 | 3 | 2 | 3 |
| 10 | Re-verify | 2 | 3 | 0 | 2 |
| 11 | Re-verify | 2 | 2 | 0 | 2 |
| 12 | Re-verify | 1 | 2 | 0 | 1 |
| 13 | Re-verify | 1 | 1 | 0 | 1 |
| 14 | Re-verify | 1 | 1 | 0 | 1 |
| 15 | Re-verify | 0 | 1 | 0 | 0 |
| 15 | Full sweep | 8 | 0 | 0 | 8 |
| 16 | Fix round | - | - | - | 8 |
| 17 | Re-verify | 6 | 7 | 1 | 7 |
| 18 | Re-verify | 3 | 7 | 0 | 3 |
| 19 | Re-verify | 1 | 3 | 0 | 1 |
| 20 | Re-verify | 0 | 0 | 1 | 1 |
| 21 | Re-verify | 0 | 1 | 0 | **0** |

Rounds 9 to 14 were a chain in the date picker (VISUAL-R10-01 to R14-01):
each fix to the stock Material picker exposed the next issue, until round 15
found none. Rounds 17 to 21 were the same pattern in names and notes
(NameText, the notes counter and caps).

## 5. Findings

### 5.1 Open findings (0)

None. No `skip:` repro of a finding is left in the suite.

The 41 findings closed after round 6 (the rounds 1 to 6 list is in 5.2):

| ID | Severity | Closed in round |
|---|---|---:|
| MONEY-R3-05, MONEY-R4-01, MONEY-R4-04, MONEY-R6-01 | Minor | 8 |
| SYNC-R6-01, DATA-R6-02, UIFLOW-R6-01, VISUAL-R6-01, SECURITY-R6-01 | Minor | 8 |
| DATA-R6-01 | Trivial | 8 |
| DATA-R8-01, UIFLOW-R8-01, VISUAL-R8-01 | Minor | 9 |
| VISUAL-R9-01 | Major | 10 |
| SYNC-R8-01, UIFLOW-R8-02 | Minor | 10 |
| VISUAL-R10-01, VISUAL-R10-02 | Minor | 11 |
| VISUAL-R11-01 | Major | 12 |
| VISUAL-R11-02 | Minor | 12 |
| VISUAL-R12-01 | Minor | 13 |
| VISUAL-R13-01 | Minor | 14 |
| VISUAL-R14-01 | Minor | 15 |
| UIFLOW-R15-01, UIFLOW-R15-02, UIFLOW-R15-03, VISUAL-R15-01, SECURITY-R15-01, SECURITY-R15-02, PLATFORM-R15-01 | Minor | 17 |
| DATA-R15-01, UIFLOW-R17-01, UIFLOW-R17-02, VISUAL-R17-01, SECURITY-R17-01, PLATFORM-R17-01 | Minor | 18 |
| SECURITY-R17-02 | Trivial | 18 |
| DATA-R18-01, DATA-R18-02, UIFLOW-R18-01 | Minor | 19 |
| UIFLOW-R19-01 | Minor | 21 |

### 5.2 All findings with final status

Status key: "Closed, fixed (round N)" means fixed by an engineer and
re-verified by QA in round N. "Reopened" is how many times a fix failed
re-verification. No finding is open and none was closed as not a defect.
Rows are grouped by area, then by the round the finding was raised in.

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
| MONEY-R3-05 | Minor | A pasted text with several numbers is joined into one amount, and a multiplier suffix is dropped ('Rs 500 paid at Cafe 21' becomes ₹50,021, '2.5k' becomes ₹2.50) | R3 | 3 | Closed, fixed (round 8) |
| MONEY-R3-06 | Minor | TND '1,250' means 1.250 DT when typed in the amount field but 1,250 DT in split fields, the multi-payer sheet and a paste | R3 |  | Closed, fixed (round 4) |
| MONEY-R4-01 | Minor | A short dot group typed in a no-decimal currency is held as grouping: JPY '800.50' becomes ¥80,050, KRW '5.00' becomes ₩500 | R4 | 2 | Closed, fixed (round 8) |
| MONEY-R4-02 | Minor | TND amount field shows 1,250 DT as '1,250' but reads a pasted '1,250' as 1.250 DT | R4 |  | Closed, fixed (round 5) |
| MONEY-R4-03 | Minor | Split and payer fields strip currency words before reading: a pasted 'Rs. 50' or 'Rs.50' becomes ₹0.50 | R4 |  | Closed, fixed (round 5) |
| MONEY-R4-04 | Minor | Adjustment field saves a minus written as an en dash, in brackets or after the number as a plus | R4 | 2 | Closed, fixed (round 8) |
| MONEY-R5-01 | Minor | A cent, pence, percent or fraction mark after the number is dropped: '99¢' becomes $99, '50p' becomes £50 | R5 |  | Closed, fixed (round 6) |
| MONEY-R6-01 | Minor | A dot-grouped number whose last group is short is read as grouping: EUR '1.200.50' becomes €120,050, USD paste '1.200.50' $120,050 | R6 |  | Closed, fixed (round 8) |

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
| SYNC-R6-01 | Minor | After a rename while visible, a missed mDNS goodbye leaves the old LAN service cached, so the Nearby row keeps flipping between the old and the new name | R6 |  | Closed, fixed (round 8) |
| SYNC-R8-01 | Minor | A stale cached sighting of a phone's old name replaces its live renamed service, and when the old record expires the phone disappears from Nearby although it is still advertising | R8 | 1 | Closed, fixed (round 10) |

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
| DATA-R6-02 | Minor | A profile name that shows nothing is accepted at onboarding, then no group can be created | R6 |  | Closed, fixed (round 8) |
| DATA-R6-01 | Trivial | A phone name that shows nothing (zero-width space, Hangul filler, braille blank) is shown as a blank name on the other phone | R6 |  | Closed, fixed (round 8) |
| DATA-R8-01 | Minor | A name that fits the 40-character field is refused when saved because normalising makes it longer | R8 |  | Closed, fixed (round 9) |
| DATA-R15-01 | Minor | Member and group names that NFKC expands make every replay over 1 ms an op (~80x an ordinary op); a peer's renames can stall app start for tens of seconds | R15 sweep | 1 | Closed, fixed (round 18) |
| DATA-R18-01 | Minor | Peer member names holding many distinct astral code points grow the normaliser caches without bound (~130 MiB) and slow every open (13k ops open in ~4.5 s) | R18 |  | Closed, fixed (round 19) |
| DATA-R18-02 | Minor | The DATA-R15-01 perf bounds in name_replay_perf_test.dart fail under the full suite's -j 2 load, so the suite is not reliably green | R18 |  | Closed, fixed (round 19) |

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
| UIFLOW-R6-01 | Minor | A Hangul filler or braille blank in place of the space gets 'Rahul&lt;filler&gt;Kumar' past the duplicate check, and it shows as a second 'Rahul Kumar' | R6 |  | Closed, fixed (round 8) |
| UIFLOW-R8-01 | Minor | A name that fits the 40-character counter but grows when normalised (for example it ends in '…') is refused: onboarding, Settings &gt; your name and phone name say 'That did not work. Try again.' | R8 |  | Closed, fixed (round 9) |
| UIFLOW-R8-02 | Minor | A profile name with no letter or number, saved by an earlier build (for example '😎'), blocks New group with 'Check the highlighted fields.' and nothing is highlighted | R8 | 1 | Closed, fixed (round 10) |
| UIFLOW-R15-01 | Minor | Edit group refuses every change to a group whose untouched name came from an older phone with no letter or number | R15 sweep |  | Closed, fixed (round 17) |
| UIFLOW-R15-02 | Minor | Edit payment cuts a Settle up note longer than 500 characters to 500 on the first key typed in it | R15 sweep |  | Closed, fixed (round 17) |
| UIFLOW-R15-03 | Minor | A note added on Settle up cannot be removed: the notes prompt keeps Save off while it is empty | R15 sweep |  | Closed, fixed (round 17) |
| UIFLOW-R17-01 | Minor | Edit group sends a field the user never touched when another phone changed it while the form was open | R17 |  | Closed, fixed (round 18) |
| UIFLOW-R17-02 | Minor | The Settle up notes prompt takes a note the Ledger refuses as too long, and says nothing until Record | R17 |  | Closed, fixed (round 18) |
| UIFLOW-R18-01 | Minor | Hidden characters take room in the notes and description caps, so a paste is cut and typing is refused while the counter shows room | R18 |  | Closed, fixed (round 19) |
| UIFLOW-R19-01 | Minor | Settle up notes counter leaves out line breaks and spaces typed at the end, so it shows room while the next letter is refused | R19 | 1 | Closed, fixed (round 21) |

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
| VISUAL-R6-01 | Minor | Multi-payer sheet squeezes 'Split the rest equally' beside 'Done': the label takes 2-5 lines and 'equally' breaks mid-word at 320 dp 2.0x | R6 |  | Closed, fixed (round 8) |
| VISUAL-R9-01 | Major | Kit buttons wrapped in Semantics(button: true, excludeSemantics: true) have no semantic tap action, so TalkBack cannot activate them | R9 |  | Closed, fixed (round 10) |
| VISUAL-R11-01 | Major | The input-only date picker takes US month-first dates and shows no format, so a date typed day-first is saved as a different date | R11 |  | Closed, fixed (round 12) |
| VISUAL-R8-01 | Minor | Split-row and multi-payer amount fields are 42.8 dp tall at 1.0x (45.9 dp at 1.15x), under the 48 dp tap target | R8 |  | Closed, fixed (round 9) |
| VISUAL-R10-01 | Minor | At 2.0x text the date picker header overflows by 46 dp and the chosen date wraps over the calendar's month row | R10 |  | Closed, fixed (round 11) |
| VISUAL-R10-02 | Minor | Date picker day cells are under the 48 dp tap target (37.7 x 36.6 dp at 320 dp, 43.4 x 46.9 dp at 360 dp) | R10 |  | Closed, fixed (round 11) |
| VISUAL-R11-02 | Minor | In the dark theme the date picker's secondary text (year list, 'Select date', 'Enter Date' label) has 4.28:1 contrast, below 4.5:1 | R11 |  | Closed, fixed (round 12) |
| VISUAL-R12-01 | Minor | The date field writes a five-digit year that its own parser refuses, so OK on an unchanged 1 Jan 10000 shows 'Invalid format.' | R12 |  | Closed, fixed (round 13) |
| VISUAL-R13-01 | Minor | Above 1.0x text the date picker's year list opens scrolled away from the selected year, so 2026 is off screen at 2.0x and a far date is hundreds of years off | R13 |  | Closed, fixed (round 14) |
| VISUAL-R14-01 | Minor | Rotating the phone, switching the theme or some text size changes while the year list is open throw away where the user scrolled and jump back to the selected year | R14 |  | Closed, fixed (round 15) |
| VISUAL-R15-01 | Minor | Currency picker cuts currency symbols with an ellipsis in its fixed 40 dp leading box (MOP$ and Sh.So. at 1.0x; KD, AED, CHF, HK$ and 52 others at 2.0x) | R15 sweep |  | Closed, fixed (round 17) |
| VISUAL-R17-01 | Minor | The VISUAL-R15-01 fix lets a long currency symbol push the currency code behind the ellipsis on the New group, Edit group and onboarding currency tile at large text | R17 |  | Closed, fixed (round 18) |

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
| SECURITY-R6-01 | Minor | On a phone whose clock was reset to 1970 the editors' date picker ends at 1971-12-31, so a new expense can never be given the real date | R6 |  | Closed, fixed (round 8) |
| SECURITY-R15-01 | Minor | A stranger flooding mDNS adverts makes LAN/Nearby discovery cubic and stalls the UI isolate | R15 sweep |  | Closed, fixed (round 17) |
| SECURITY-R15-02 | Minor | A crafted settleup:// link name makes invite and connect link parsing quadratic (UI freeze) | R15 sweep |  | Closed, fixed (round 17) |
| SECURITY-R17-01 | Minor | A stranger flooding mDNS adverts makes the Sync screen build every forged row on each list change | R17 |  | Closed, fixed (round 18) |
| SECURITY-R17-02 | Trivial | The HELLO group id guard in crypto_test is flaky on random ephemeral keys | R17 |  | Closed, fixed (round 18) |

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
| PLATFORM-R15-01 | Minor | NameText.normalize/fit are not idempotent after a joiner followed by a dropped invisible, so the stored name differs from the shown name | R15 sweep |  | Closed, fixed (round 17) |
| PLATFORM-R17-01 | Minor | The repeated clean-up pass makes NameText quadratic | R17 |  | Closed, fixed (round 18) |

## 6. Device-only checks for the owner's test phone

None of these were run: no emulator or phone was available. They are merged
and deduplicated from every area's device notes in rounds 1 to 21 and from
TEST-PLAN section 7. Tick each one and note the phone, Android version and
result. Radio steps in detail: [../QA.md](../QA.md). Many need two phones
(marked **2P**). Finding ids show which fix a check confirms on hardware.

### 6.0 Before a production release

These are the checks QA would want passed before Play production. They come
from the subsections below:

- [ ] Release-signed APK built from `dev`, installs, opens as "Settle Up" with
  the custom adaptive icon, and cold starts on API 26 and API 36 with nothing
  stripped by R8 (6.1).
- [ ] Startup error screen with a corrupt or newer `settle_up.db` (6.1).
- [ ] Permissions on API 29/30, 31/32 and 33+, including permanent denial and
  the radio switches off (6.2).
- [ ] **2P** invite by QR, first sync and claim, then sync over LAN (hotspot),
  Nearby and BLE, with balances equal on both phones (6.3).
- [ ] Keystore-backed group keys survive an app update and a reboot (6.4).
- [ ] Amount entry with Gboard and Samsung Keyboard in INR and EUR (6.5).
- [ ] TalkBack can activate every control listed under VISUAL-R9-01 (6.7).
- [ ] The date picker at 2.0x text with Gboard up, and day-first typed dates
  (6.8).

### 6.1 Install, signing, startup

- [ ] Build the final APK from `dev` with a real `android/key.properties` and
  confirm the debug-key warning is gone and the APK is release-signed
  (PLATFORM-R1-06, PLATFORM-R2-02). The local build here is debug-signed.
- [ ] The installed app shows "Settle Up" with the custom adaptive icon in the
  launcher, the Android 13+ themed icon and recents.
- [ ] 0.1.0 tester installs: 1.0.0 has a new app id and key, so it installs as
  a second "Settle Up". Follow the release-notes install note (sync, rejoin
  by invite, uninstall 0.1.0) and check `settleup://` links open the 1.0.0 app.
- [ ] Upgrade over an earlier 1.0.0+2 test install. versionCode is still 2, so
  Android treats it as a reinstall of the same version. The database opens
  unchanged, HLC and counters continue, group keys still decrypt, and names
  stored before NFKC normalisation (for example the phone name) keep working.
- [ ] UIFLOW-R8-02 upgrade path: on an earlier preview APK, finish onboarding
  with an emoji-only name (or one over 40 characters), upgrade to the release
  APK, accept an invite from a second phone and tap Which one are you? > I'm
  not on the list. You are added and the group opens with no error. Then
  change Settings > your name and check the name changes in that group on
  both phones after a sync. **2P**
- [ ] Cold start the release APK on API 26 and on API 36: nothing that the
  plugins load by reflection was stripped by R8 (nearby_connections/GMS,
  bluetooth_low_energy, mobile_scanner/ML Kit, flutter_secure_storage with
  Tink, bonsoir/gson, cryptography_flutter, path_provider over jni). The app
  has no `proguard-rules.pro` of its own and relies on the plugins' consumer
  rules.
- [ ] Merged manifest of the release APK (`aapt2 dump xmltree`): permissions,
  `dataExtractionRules`, deep-link filters and no debug flags.
- [ ] Startup error screen: install over a newer-schema database (`adb install
  -d`) or a corrupt `settle_up.db`; the error screen shows and Try again
  reopens the file once it is fixed (DATA-R1-02, PLATFORM-R1-01).
- [ ] Cold open and replay of a 20k-op log across 10 groups on a mid-range
  phone in release (host: 0.65-0.86 s against a 2 s budget; open and replay
  run before `runApp`). Note RSS after open (`adb shell dumpsys meminfo`;
  host +54 MiB).
- [ ] Pathological peer names, release (AOT) build: cold open of a group with
  20k peer members whose names are mark-heavy (for example 'x' + 158 x U+0F77,
  or 4,000 x 'x' + 158 x U+0344), and of 13k-20k member creates whose names
  cover the astral code points. Open time stays well under the ANR threshold
  and RSS does not grow by tens of MiB (DATA-R15-01, DATA-R18-01; host JIT:
  about 1.3 s for the 20k mark-heavy log).
- [ ] Per-command latency during a live sync with 20k ops (host: addExpense
  about 3 ms, applyRemote of a 1,000-op batch 88 ms).
- [ ] Full disk: the app opens and shows balances; adding an expense shows the
  storage error and works after space is freed; first launch on a full disk
  (DATA-R1-02/04/07).
- [ ] Kill the app (`adb shell am kill`, and `kill -9` of the process)
  mid-commit, mid-createGroup and mid-sync (large applyRemote) on both phones;
  relaunch: no op lost, counters contiguous, no ghost group, no half-applied
  batch, no duplicates on resync, unshared counts correct (DATA-R1-08). **2P**
- [ ] Launch screen on API 26-30 (stone with the tether, light and night) and
  the API 31+ splash; pick Dark in Settings with the system light, then cold
  start: the splash is dark (PLATFORM-R1-05, VISUAL-R1-14).
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
  sync, no crash (PLATFORM-R1-09). **2P**
- [ ] Turn Bluetooth and Wi-Fi off and on while the Sync tab is open: the
  state is reported without a crash and the Open settings / Turn on actions
  work (API 26-30 location switch, API 31+ BLUETOOTH_*, API 33+
  NEARBY_WIFI_DEVICES).

### 6.3 Sync on real radios (**2P** unless noted)

- [ ] Invite QR with the `h=` host hint over a Wi-Fi hotspot, then the first
  sync and the claim back. Loopback covers the protocol but not real hotspot
  or AP isolation.
- [ ] LAN on a router and on an Android hotspot: mDNS discovery, hotspot
  gateway probe, invite `h=` host when the phone has cellular, VPN and hotspot
  interfaces at once (QA.md 2).
- [ ] Transport fallback on hardware: LAN blocked by AP isolation, then
  Nearby, then BLE. The nearby list shows one row per phone on Nearby and
  mDNS (the SightingCache behaviour is proven only with scripted events).
- [ ] BLE GATT at 16 KiB frames: throughput for 2,000+ ops, and the
  disconnect after BYE records a complete sync on both phones (SYNC-R1-04).
- [ ] Interrupted BLE sync (walk out of range mid-batch): the result is
  partial, the next sync completes and the unshared badge is correct.
- [ ] Nearby Connections: latency; the v2 endpoint name (24 tokens, advert
  id, window tag, trailing `+`, up to 131 bytes) is accepted by
  `startAdvertising` and survives discovery (SYNC-R1-07, SYNC-R2-01).
- [ ] Android NSD/bonsoir accepts the 4-key TXT record (`t`, `t1`-`t3`, up to
  243 bytes each, about 1,000 bytes in all).
- [ ] With many groups (over 4 on Nearby, over 16 on BLE/LAN) the shared group
  still shows "Sync", not "Pair", across several 10-minute windows.
- [ ] Re-advertising on Nearby (each 10-minute window, and after a rename):
  does the endpoint id change, and how quickly do discoverers get
  `onEndpointLost` for the old one? The Nearby row is not duplicated and Sync
  never dials the dead old endpoint. NearbyTransport drops an older endpoint
  with the same advert id; a window change has a new advert id, so only the
  loss event can clean that case up.
- [ ] Rename while visible, LAN (SYNC-R5-01, SYNC-R6-01, SYNC-R8-01): Alex
  hosts as "Pixel 8" on a hotspot and renames to "Alex's phone" while Priya
  is on the Sync screen. Priya's row shows only the new name within seconds.
  Priya then leaves and reopens the Sync screen within about 2 minutes, while
  the old mDNS record is still cached: check whether Android/bonsoir
  re-reports the old service and in which order, that the row does not flip
  back, and that Alex is still listed after the old record expires.
- [ ] Rename while visible, Nearby (SYNC-R8-01): the same steps. Check whether
  a restarted discovery replays the old endpoint after the new one, and that
  only the new name is listed. Then Alex renames and stops hosting: Priya's
  row goes away and does not switch back to the old name. The fix relies on
  `onEndpointLost` for the old endpoint; if a phone misses it, the old
  endpoint resurfaces once the new one is lost and is re-sent every 5 s until
  discovery stops (accepted design from round 8; Nearby has no TTL, unlike
  mDNS). Record whether Nearby ever misses a loss.
- [ ] Rename while visible, BLE only: a scanner keeps the old name for up to
  the 60 s INFO cache, without flipping. Confirm this is acceptable. Rename
  during a running Nearby sync: the connection is not dropped.
- [ ] A phone name that shows nothing (only U+200B or a Hangul filler, set
  through an older build or a forged HELLO): the other phone's nearby list,
  session screen and Sync history read "Phone", never "Synced with " with
  nothing after it (DATA-R6-01).
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
  looks wrong"; edits after the sync take effect on both (SYNC-R1-01). With
  three phones and one at +2 h, gossip converges on all of them and the skew
  notice shows. **3 phones**
- [ ] Wi-Fi lost mid-sync (half-open TCP): how long the host stays busy, and
  the retry from the same phone is accepted and resumes without duplicates
  (SYNC-R1-05).
- [ ] Hosting expiry (5 min) and token rotation across a real 10-minute
  boundary while advertising on all radios.
- [ ] Settle up over a real transport: record a partial payment and an
  over-payment on one phone, sync, and check both phones show the same
  direction flip and the same balances on Group, People and the Home hero.
- [ ] Both phones record the same cash payment offline, then sync: the
  balance flips and the possible-duplicate hint shows (MONEY-R1-06).
- [ ] Concurrent edits (UIFLOW-R17-01): keep Edit group, the expense editor and
  Edit payment open on phone A while phone B renames the group or changes the
  expense amount or date and syncs over LAN. Save an unrelated change on A
  and check B's change survives on both phones after the next sync.
- [ ] How cut names look on the peer: a long Devanagari phone name cut to the
  63-byte mDNS label, flag or conjunct cuts in Nearby/BLE names, and a name
  with U+FFFD in the Sync screen and history (DATA-R4-03, DATA-R5-01).

### 6.4 Security and privacy

- [ ] Stranger phone without the key: Nearby auto-accepts the endpoint, the
  session layer refuses it, no crash, no stuck session. **2P**
- [ ] A stranger flooding TCP connects from one IP (with and without HELLOs)
  while a friend syncs: the friend still gets in (SECURITY-R2-03). **3 phones**
- [ ] Discovery flood (SECURITY-R15-01, SECURITY-R17-01): on a release APK on a
  mid-range phone, a laptop on the same hotspot announces 1,000+ forged
  `_settleup._tcp` services (`avahi-publish` or `dns-sd` loop, `v=2` TXT,
  distinct ports, no goodbyes) and renames or withdraws one every second.
  With the performance overlay on: the Sync screen scrolls without dropped
  frames, there is no ANR, a phone that shares a group stays at the top of
  Nearby phones, and note how fast Android NSD actually resolves services.
  With TalkBack on, swiping reads the rows in order and focus does not jump
  when a forged row above it changes. Repeat for Nearby with many endpoints.
- [ ] Crafted links (SECURITY-R15-02, PLATFORM-R17-01): tap a
  `settleup://join` link whose `n=` holds 20k-100k combining marks (about
  150 KB), and one whose `n` and `f` are 960-unit joiner cascades, from a
  chat app and from a browser. The join screen opens in well under a second
  with no ANR (host: 2-2.5 ms warm). Also check the largest URL Android passes
  to the activity and that a link of about 1 MB does not crash the app.
- [ ] Capture TCP 52741 on a hotspot (Wireshark/PCAPdroid): only HELLO, AUTH
  and ERROR are plain; no group id or name in clear.
- [ ] mDNS browser and nRF Connect: TXT/INFO/endpoint names show rotating
  tokens and a rotating advert id only; no group id, no key, no stable device
  id prefix (SECURITY-R1-12).
- [ ] Release logcat during invite, join and sync: no group key, invite link
  or payload printed.
- [ ] Invite QR: screenshots and screen recordings are black, the recents
  thumbnail is blank while it shows, and both work again after the 2-minute
  auto-hide or on leaving the screen (SECURITY-R1-09). Time the auto-hide.
- [ ] Scan a QR with mobile data on: nothing goes to
  `firebaselogging-pa.googleapis.com` (SECURITY-R1-13).
- [ ] Open `settleup://sync?h=203.0.113.7:52741` from a browser before and
  after onboarding: no connection attempt. Note: loopback is still dialed by
  design (SECURITY-R1-14).
- [ ] Android 12+ device-to-device transfer (Pixel "Copy apps & data",
  Samsung Smart Switch) and `adb shell bmgr`: `settle_up.db` and the
  secure-storage prefs are not copied; the new phone starts fresh with a new
  device id (SYNC-R1-08, SECURITY-R1-07, PLATFORM-R1-03).
- [ ] Keystore: group keys survive an app update, a reboot and an OS update
  (SecureGroupKeyStore is faked on the host). Keystore disruption (remove or
  change the screen lock, OEM reset, or delete the alias in a debug build):
  flutter_secure_storage reports the key mismatch, the app shows the
  recovery, and re-scanning an invite stores the key again; creating a group
  works (SECURITY-R1-11, SECURITY-R2-02).

### 6.5 Amount entry on real keyboards

- [ ] Gboard, Samsung Keyboard and SwiftKey, `numberWithOptions(decimal:
  true)`, in de_DE, fr_FR, hi_IN and ja_JP: which separator keys the keypad
  offers; '12,50' is 12.50 in the amount field and in the split fields; the
  field rewrites a typed ',' as '.' (EUR '1234,5' gives 1,234.5); lakh and
  comma-grouped amounts (MONEY-R1-02/04, MONEY-R2-01, MONEY-R2-04).
- [ ] INR, EUR, JPY and KWD: '1,234.50', '1.234,50', KWD '12.345', JPY
  '1,234'; typing ',' and '.' in TND, KWD, VND and IDR (MONEY-R3-02,
  MONEY-R3-03, MONEY-R4-01, MONEY-R6-01). A text that holds no amount (EUR
  '1.200.50') shows "Enter the amount as a number" or the decimals message,
  and TalkBack reads that hint.
- [ ] Paste '-30' and U+2212 '−30' into Adjust; they are read as minus
  (MONEY-R4-04).
- [ ] A Japanese IME that types full-width digits ('１２００') and
  Arabic/Persian keyboards that type Eastern Arabic digits: the field refuses
  them with a message; check a real user can still enter an amount by
  switching to ASCII digits.
- [ ] The big amount field is a 2-line TextField (`maxLines: 2`): the action
  key moves focus (`textInputAction.next`) and inserts no newline, a hardware
  Enter does not break the layout, and a pasted line break is refused.
- [ ] Select-all paste over an existing amount from the real text toolbar
  (MONEY-R2-05, MONEY-R3-01).
- [ ] Amount near the cap (UIFLOW-R2-02).
- [ ] Tapping the currency symbol in the Amount field (48 dp target with a
  chevron) opens the currency picker, and changing currency keeps the typed
  amount readable in the new currency's grammar.
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
  Gmail, Drive and WhatsApp; the behaviour when no app handles ACTION_SEND
  (MONEY-R1-09, UIFLOW-R1-09).
- [ ] CSV opened in Google Sheets, Excel for Android and WPS: non-ASCII text
  is correct (UTF-8 BOM); descriptions and names starting with '=', '+', '@'
  or a tab stay text; negative amounts stay numbers; CRLF rows and multi-line
  descriptions import as one row each.
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
  field shows the whole amount, focused and unfocused (VISUAL-R4-02). The
  currency chevron at 320 dp with Money.maxMinor in INR and KWD never cuts
  the amount.
- [ ] Android 14 nonlinear font scaling (130%-200%) on split rows.
- [ ] Keyboard open (gesture and 3-button nav) on Add expense, Search and the
  pay-part sheet on a short phone: Save bar, split summary, exact/percent
  inputs and Done stay visible; Search no-results stays scrollable.
- [ ] Typing a share in exact, percent and adjustment rows and in the
  multi-payer sheet at 320-360 dp, 1.0x and 1.3x: the keyboard stays open when
  a row switches between beside and stacked (VISUAL-R5-01).
- [ ] Multi-payer sheet (Paid by > Multiple people) at 320-360 dp, 1.0x and
  Largest: "Split the rest equally" and "Done" sit side by side only when both
  fit on one line, otherwise they stack full width with no word broken;
  TalkBack reads both and announces "Done" as disabled until the payers add
  up (VISUAL-R6-01).
- [ ] Tap targets at 1.0x and 1.15x (VISUAL-R8-01): tap the top and bottom
  edges of a split-row amount field, a multi-payer amount field and the
  labelled Description/Name fields. Each focuses the field and opens the
  keyboard, and the text sits centred in the 48 dp box.
- [ ] Taps in the 48 dp TapTargetPadding margins above and below the split,
  group, category and sync chips trigger the chip and do not steal taps from
  the neighbouring rows or the text field next to the category chip.
- [ ] TalkBack actions (VISUAL-R9-01): double-tap each formerly dead control
  and check it acts and is announced correctly: split method chips
  (checked/unchecked), the Group and Category chips on Add expense, Paid by /
  Date / Currency pickers (expense editor, New group, Edit group), Settle up
  Date and Note rows, the amount field's currency symbol ("Indian rupee
  (INR)" button), the Shares weight ("Shares for X. Tap to type"), the Home
  and group sync chip, the balance hero, and Nearby Sync/Pair, where the row
  is one node ending "Sync with <phone>".
- [ ] TalkBack walk-through of Home, Group, Settle up, Add expense and Sync:
  focus order, merged row labels, hero sentence, the Sync card announced once
  (VISUAL-R1-09), amounts and direction words in "What changes" and expense
  rows for a multi-currency pair, the selected group-type chip and payment
  method.
- [ ] Currency picker and the New group / Edit group / onboarding currency
  tile at Largest (2.0x) on a 320-360 dp phone, default size too: KD, CHF,
  HK$, MOP$ and Sh.So. show whole, and "<name> (<code>)" is not pushed behind
  an ellipsis; TalkBack reads "Currency, <name> (<code>)" (VISUAL-R15-01,
  VISUAL-R17-01). Repeat with Android 12+ Settings > Display > Bold text on,
  with SOS, MOP or XAF at 2.0x on 320 dp: PickerTile measures without the
  bold merge, so only synthetic bold on a device could make the text wider
  than measured.
- [ ] Light theme: the currency prefix (₹) in the split amount fields is
  readable by eye (specified colours 5.11:1; the test checker measures 3.12:1
  from anti-aliased edges).
- [ ] Onboarding at 1.0x: the helper texts ("Friends see this when you
  sync.", "Groups can use other currencies.") and the "Sync it" link are
  readable by eye (5.56:1 light, 7.76:1 dark; the test guideline fails them
  only on its 1x downscaled sample).
- [ ] Sync > Make this phone visible on a 320-360 dp phone: the "Hotspot:
  <name>" line sits half under the Stop bar until the list is scrolled; check
  it scrolls fully into view and reads clearly in both themes.
- [ ] "Remove animations" (developer and accessibility settings) during a real
  sync: spinners, the sync progress bar, the settle dot and the tether are
  still (VISUAL-R1-13, VISUAL-R2-05).
- [ ] Android 15+ edge to edge: status and gesture bars over the stone
  background; FAB and Save bar above the gesture pill.
- [ ] Lagoon and Kiln direction colours in sunlight and on AMOLED dark.

### 6.8 Dates and time zones (release build, asserts stripped)

- [ ] Edit an expense dated 1970 and one dated 2090: the date picker opens on
  that date (SECURITY-R5-01).
- [ ] Clock reset (SECURITY-R6-01): set the phone clock to 1970-01-01 (auto
  time off), open Add expense, a payment edit and Settle up, and in each use
  the year grid and the text entry to choose today's real date. Save, and
  check the saved date is right on a peer after sync. **2P**
- [ ] At font size 2.0x on 320 dp and 360 dp phones with Gboard up, from the
  expense editor, the payment editor and Settle up: no header overflow
  (VISUAL-R10-01); in input mode the field and OK/Cancel stay above the
  keyboard and nothing overlaps; the pencil (switch to input) is reachable
  with TalkBack; day cells are easy to hit (VISUAL-R10-02).
- [ ] Input mode (VISUAL-R11-01): the `TextInputType.datetime` keyboard offers
  '/', so dd/mm/yyyy can be typed; a day-first date such as 09/11/2026 saves
  as 9 November; the floating label "Date (dd/mm/yyyy)" stays readable with
  Gboard up at 320 dp and 2.0x.
- [ ] TalkBack on the picker: calendar day cells read as full dates and the
  year list is reachable; the input field reads "Date (dd/mm/yyyy)" and its
  value understandably.
- [ ] Dark theme on an OLED panel: the year list, the "Enter Date" label and
  the field outline are readable and visible (VISUAL-R11-02).
- [ ] Phone set to UTC+05:30: take an expense a peer dated 9999-12-31 18:30
  UTC or later, open Date and tap OK unchanged. The dialog closes and the
  expense saves on 1 Jan 10000 (VISUAL-R12-01; verified in widget tests under
  TZ=Asia/Kolkata and Pacific/Kiritimati only).
- [ ] Year list at 1.3x and 2.0x (VISUAL-R13-01): it opens with the selected
  year visible and highlighted on the first frame, with no jump or
  spring-back, in all three editors, with Familjen Grotesk and real system
  text scaling.
- [ ] Year list kept on configuration changes (VISUAL-R14-01): scroll it, then
  rotate, toggle system dark mode and change the font size while it is open.
  It stays where you scrolled it.
- [ ] A non-UTC time zone: a picked day keeps the original time of day and
  does not shift by a day around midnight.
- [ ] Time zone Asia/Kolkata, then Pacific/Kiritimati: a group holding
  expenses dated 1900-01-01 UTC and 9999-12-31 UTC renders (SECURITY-R4-01).

### 6.9 Names, notes and text caps on real keyboards and fonts

- [ ] Blank names (DATA-R6-02): type a Hangul filler or a braille blank as
  Your name in onboarding and Settings > Edit name. Start/Save stays disabled
  and "needs a letter or number" shows under the field.
- [ ] Filler look-alikes (UIFLOW-R6-01) on real Android fonts: 'Rahul' +
  U+3164 / U+115F / U+1160 / U+FFA0 / U+2800 + 'Kumar' in Members > Add person
  is refused next to "Rahul Kumar" and draws as "Rahul Kumar" (Noto CJK and
  Noto Symbols draw these as blanks; the test engine only proves they are not
  zero width). Also check U+1D159 MUSICAL SYMBOL NULL NOTEHEAD between two
  words: NameText keeps it as visible; if the device draws it blank, it
  belongs to the same class.
- [ ] Names that grow when normalised (DATA-R8-01, UIFLOW-R8-01): in onboarding
  Your name, Edit name, Phone name, a New group member and the group name,
  type or paste U+337F x 11, U+FDFA x 3, 38 x 'a' + U+3231 and a 60-character
  group name of U+337F. The counter stops at the limit, Save keeps the name
  cut to the limit with no "That did not work" snack, and the name looks the
  same after a force stop. Paste 'ﷺ' + 30 letters into Settings > your name:
  40/40, the ligature is shown expanded; check how its 18-character form
  looks in the Settings row and in member avatars.
- [ ] IME composing near a cap (Gboard, Samsung Keyboard): type 39 letters
  then '...' (which may become '…') or '½' while a word is composing. The
  field may run over while composing, shows "That is too long. Make it
  shorter." with Save / Get started disabled, and on commit is cut to 40 with
  the cursor in place and nothing doubled or lost. Tapping Save while still
  composing never saves an over-long name. Note how often a real keyboard
  produces the expanding characters.
- [ ] Settings > Your name and Settings > Phone name at the largest font size
  on a small phone with a 40-character name: the dialog stays whole above the
  keyboard (widget tests used a fake 260/290 dp inset).
- [ ] Joiners decided by the bases around them (PLATFORM-R15-01,
  PLATFORM-R17-01): names with a Malayalam chillu mid-word, Sinhala
  yansaya/rakaransaya, Bengali ZWJ before the virama, Persian ZWNJ and emoji
  ZWJ sequences with skin tones and selectors look as typed on the device
  fonts (stored code points are covered by
  `test/qa/platform/round18_test.dart`).
- [ ] Long notes (UIFLOW-R15-02): with Gboard word composition, type and paste
  into an 800-character held note in Edit payment, the expense editor and the
  Settle up prompt. The note is never cut, and a composed word that crosses
  1,000 is held to the cap.
- [ ] Expense description (multiline, `TextInputAction.done`): the Done key
  moves on or submits and inserts no line break.
- [ ] Hidden characters in notes (UIFLOW-R17-02, UIFLOW-R18-01): paste a long
  emoji note, and a note with zero-width spaces or bidi marks, into Settle up
  notes, the expense notes and the description. The paste is kept whole,
  typing goes on while the counter shows room, the counter and "That is too
  long" agree and Save is off when over; composing a word at the cap does not
  cut text.
- [ ] Notes counter edges (UIFLOW-R19-01): in Settle up > Notes press Enter
  twice, type to 998 letters (counter 1000/1000), move the cursor to the very
  start and type a letter: it is refused. A letter typed just after the
  breaks goes in, Save stays on and no "too long" message shows. Two Enters
  typed at the end of 998 letters give 1000/1000, also while autocorrect is
  composing. TalkBack reads the remaining count as 0 when the counter is full
  and as the shown room otherwise.
- [ ] Edit group on a group whose name came from an older phone with no letter
  or number (UIFLOW-R15-01): another field can be changed and saved; a note
  added on Settle up can be removed (UIFLOW-R15-03). **2P**

## 7. Residual risks

### 7.1 Product

1. **Radios are verified only on the host.** The engine, protocol and LAN
   transport ran for real over 127.0.0.1; Nearby and BLE were tested through
   their Dart layers only, without the real platform plugins. Throughput,
   MTU, advert size limits, endpoint id behaviour (the SYNC-R8-01 design
   assumes Nearby reports every `onEndpointLost`), mDNS caching and OEM radio
   stacks are unproven until section 6.3 is done. Highest residual risk.
2. **Permissions and OEM behaviour** (section 6.2) are unit-tested against a
   model of permission_handler; the order of results and resume events on a
   real device is not.
3. **Keystore** loss and recovery are tested against a fake of
   flutter_secure_storage 11.2.0 whose error strings were matched to the
   plugin source. A wrong match on a real OEM would show up as groups that
   work locally but cannot sync.
4. **Text handling is the most churned area.** Names, notes and caps
   (NameText normalisation, invisible and joiner handling, the counters and
   formatters) produced findings in rounds 4 to 6, 8, 15, 17, 18 and 19, and
   the last reopen (UIFLOW-R19-01, round 20). Every fix is pinned by tests
   that send one edit per code point; a real IME sends composing regions the
   harness only simulates, and device fonts decide what is blank (6.9).
5. **Amount parsing heuristics.** MONEY has 26 findings, 17 of them from
   rounds 2 to 6, nearly all in free-text parsing of typed and pasted
   amounts. None has been raised since round 6, including the round 15 full
   sweep, but the parser is still a set of rules and real keyboards may send
   edit sequences the harness does not (6.5).
6. **The date picker is a customised stock Material picker.** Rounds 10 to 14
   found one issue per round in it (layout at 2.0x, tap targets, day-first
   input, contrast, five-digit years, year list scrolling). Round 15 and the
   sweep found none, but a Flutter upgrade could change the stock parts it
   builds on; re-run `test/qa/visual/r10_regression_test.dart` to
   `r14_regression_test.dart` after any Flutter upgrade.
7. **Hostile peer data performance** (DATA-R15-01, DATA-R18-01,
   SECURITY-R15-01, SECURITY-R15-02, SECURITY-R17-01, PLATFORM-R17-01) is
   bounded by tests on the host JIT under suite load. AOT on a mid-range phone
   should be faster, but the ANR margin is measured only on a device (6.1,
   6.4).
8. **R8 at runtime.** The release build succeeds with R8 and keep rules, but
   reflection-loaded plugin classes can only be confirmed on a phone (6.1).
9. **Release APK size** is 108.7 MB for all ABIs; prefer `--split-per-abi`
   or an app bundle for distribution (README "Build").
10. **iOS** was not built or tested.

### 7.2 Process

1. **`dev` does not have the rounds 7 to 21 fixes yet** (section 1).
   `origin/dev` is `319f2f8`; `qa/integration` is 183 commits ahead. Exit
   criterion 1 counts a fix once it is merged into `dev`; squash merge with
   `tool/squash_merge.sh`, then re-run analyze and the full suite on `dev`
   before building the release.
2. **No full sweep on the final commit.** Round 15 was the last full sweep of
   all seven areas and it was not clean (8 findings). Rounds 17 to 21 were
   targeted re-verification with neighbour probes, and rounds 20 and 21 found
   nothing new. Each earlier round that followed a fix found something next to
   it, so a short confirmation sweep on `dev` after the merge would cut the
   remaining risk; it is not required by the exit criteria.
3. **Commit history.** UIFLOW-R2-05 is closed by prevention
   (`tool/git-hooks/commit-msg`, `tool/check_commit_messages.sh`,
   `tool/squash_merge.sh`, and the CI check). All 618 commits in
   `origin/main..qa/integration` and the whole of `origin/dev` are clean: no
   co-author or session trailers, and every commit is authored by sushil3125
   or fonenxtaiml. 55 stale round 1 to 5 `fix/*` branches on `origin` (for
   example `fix/qa-ui-r3`) still carry the old trailers. They are already
   merged in a clean form and must never be merged again; deleting them is
   the owner's call.
4. **Full suite timing.** DATA-R18-02 showed that perf bounds can fail under
   the `-j 2` load of a shared host. The bounds were made load-tolerant and
   the suite has been green since round 19; keep running it with `-j 2` on CI
   runners of similar size.
5. **Device pass not run.** Section 6 is entirely outstanding.

## 8. Sign-off

| Item | Status |
|---|---|
| Findings | **196 raised, 196 closed and re-verified, 0 open** (1 blocker, 5 critical, 55 major, 118 minor, 17 trivial over rounds 1 to 21) |
| Analyze | Clean |
| Tests | 3,254 total, 3,254 passed, 0 skipped, 0 failed (1,603 added by QA) |
| Release build | Builds with R8 (108.7 MB); debug-signed here (no key.properties); not published |
| Commit messages | Clean on `qa/integration` and `dev` |
| Device checks | 0 of section 6 run (no device) |
| Report clean | **Yes** (zero open findings) |
| Recommendation | **GO** for a 1.0.0 release candidate built from `dev` after the squash merge, signed with the upload key, for the owner's device pass. **GO for Play production** once section 6.0 passes on the device; any defect found there goes back through the same fix and re-verify loop |
