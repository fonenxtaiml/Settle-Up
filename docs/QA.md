# Settle Up: manual radio QA

Automated tests cover the sync protocol over in-memory channels and the LAN
transport over real sockets on 127.0.0.1 (`test/sync/lan/`). Real radios
cannot be tested in CI: hotspots, Wi-Fi multicast, Bluetooth and system
permission dialogs only exist on phones. This checklist covers that part
(SPEC 11.3, build phase 3).

Run it on a **debug or release APK built from the branch under test**. Write
the result in the tables (date, build, pass/fail, notes) and file a bug for
every failure with the phone model, Android/iOS version, and what the screen
showed.

Sections:

1. [Test phones and setup](#1-test-phones-and-setup)
2. [LAN and hotspot sync](#2-lan-and-hotspot-sync) (WP-D1)
3. [Android permissions per API level](#3-android-permissions-per-api-level) (WP-D1, used by D2)
4. [Bluetooth: Nearby Connections and BLE](#4-bluetooth-nearby-connections-and-ble) (WP-D2 fills this in)
5. [Result log](#5-result-log)

---

## 1. Test phones and setup

Minimum set:

| Phone | Role | Why |
|---|---|---|
| A: Android 14+ (API 34-36) | host / scanner | current permission model (Nearby devices group, `NEARBY_WIFI_DEVICES`) |
| B: Android 12 or 12L (API 31/32) | host / scanner | Bluetooth runtime permissions, still needs location for Nearby |
| C: Android 10 or 11 (API 29/30), optional | scanner | legacy location-for-scan path |
| D: iPhone, iOS 15+ | scanner / Personal Hotspot host | Local Network prompt, Bonjour, BLE to Android |

Before every run:

- Install the APK fresh (`adb install -r` keeps data; uninstall first when a
  test says "fresh install").
- Give every phone a different device name (Settings, Phone name) so rows are
  easy to tell apart: "Alex Pixel", "Priya Galaxy", "Sam iPhone".
- On phone A, create group "Goa trip" with 3 members and 5 expenses. Invite B
  and D with the group QR so all phones share the group.
- Turn mobile data **off** on every phone. Sync must never need the internet.
- Keep `adb logcat -s flutter` (or Xcode console) running and filter on
  `settle_up.sync`; attach the log to any bug.

Pass criteria used below:

- "Synced" = the session screen ends on the done state, both phones show the
  same expenses and balances in "Goa trip", and the Activity feed on both
  shows one sync row with the other phone's name.
- "Nothing lost" = after a failure, both phones still show every expense they
  had before, and the next sync completes.

---

## 2. LAN and hotspot sync

How the LAN transport works (so failures can be placed): the host opens a TCP
server on port **52741** (or a free port if that one is busy), announces
`_settleup._tcp` over mDNS, and shows a QR with every usable IPv4 address
(hotspot interfaces first). A scanner finds hosts three ways: mDNS, the
**hotspot gateway probe** (every 5 s it reads the Wi-Fi gateway and tries
port 52741 there; the gateway is read at runtime, never assumed), and the
**connect QR**. Frames are AES-GCM sealed by the session layer; the transport
only sees ciphertext.

### 2.1 Same Wi-Fi network (router)

| # | Steps | Expected |
|---|---|---|
| L1 | A and B on the same home Wi-Fi. A: Sync tab, "Make visible". B: Sync tab, "Find nearby". | Within 10 s B lists A by its device name, marked as sharing "Goa trip". |
| L2 | B taps A in the list. | Synced over Wi-Fi. The session screen names Wi-Fi/LAN as the transport. A accepts without any prompt. |
| L3 | Add an expense on A and another on B, sync again from B. | Both phones have both expenses. Counts on the done screen: 1 sent, 1 received. |
| L4 | A: leave the host screen open for 5 minutes. | Hosting stops by itself at the countdown; A disappears from B's list within 15 s. |
| L5 | B keeps "Find nearby" open for 2 minutes while A stays visible. | A stays in the list the whole time (no flicker away and back). |
| L6 | A: "Make visible" again. On B, scan A's QR with "Scan code". | Synced, without using the nearby list. |
| L7 | Router with client isolation (guest network or a hotel Wi-Fi), both phones on it. | mDNS finds nothing and the QR connect fails within about 4 s per address with a "could not reach" message; nothing is lost; no crash. |

### 2.2 Android hotspot

| # | Steps | Expected |
|---|---|---|
| H1 | A: turn on the system hotspot (Settings, Hotspot). B: join A's hotspot. A: "Make visible". B: "Find nearby". | B lists A within 10 s, either by name (mDNS) or as "Phone sharing its hotspot" (gateway probe). Not both. |
| H2 | B taps the row. | Synced. |
| H3 | Repeat H1 with **B as the hotspot** and A joined, A visible. | B finds A through mDNS or the QR (the gateway probe only finds the hotspot phone itself). Synced. |
| H4 | A hosts the hotspot, B joined. On A, open the host screen and check the address list. | The first address is on the hotspot interface (often `192.168.x.1` or `10.x.x.1`, never assumed). B scanning the QR syncs. |
| H5 | Hotspot with **three phones** (A host, B and C joined). B syncs with A, then C syncs with A. | Gossip: C ends with B's new expenses without ever meeting B. |
| H6 | A hosts the hotspot and is visible; B is joined. Turn A's hotspot off during a sync with many changes (seed 500 expenses first). | B's session fails with a clear message; "Nothing was lost" copy shows the partial count; after the hotspot is back, the next sync completes and no expense is duplicated. |
| H7 | While B is syncing with A, phone C also taps A. | C gets a "busy" message; B's sync is not disturbed. |
| H8 | B joined A's hotspot, A not visible (host screen closed). B: "Find nearby" for 30 s. | No "Phone sharing its hotspot" row (port closed), no error, no battery-hungry loop in logcat (one probe every 5 s at most). |

### 2.3 iPhone

| # | Steps | Expected |
|---|---|---|
| I1 | Fresh install on D. Same Wi-Fi as A. D: "Find nearby". | iOS shows the Local Network prompt with "Settle Up finds your friends' phones on the same Wi-Fi or hotspot to share expenses." |
| I2 | Allow it. A visible. | D lists A within 10 s and syncs. |
| I3 | Settings, Privacy, Local Network: turn Settle Up off. D scans A's QR. | The connect fails; the app tells the user to allow Local Network for Settle Up in Settings. No crash. |
| I4 | D turns on Personal Hotspot; A joins it; D: "Make visible". A: "Find nearby". | A lists D (by name, or "Phone sharing its hotspot" via the gateway, which iOS usually puts at `172.20.10.1`). Synced. |
| I5 | D visible on Wi-Fi; check the host screen. | Shows the Wi-Fi name when iOS provides it, and the QR addresses start with the `bridge100` hotspot address when the hotspot is on. |

### 2.4 Edge cases

| # | Steps | Expected |
|---|---|---|
| E1 | A: Wi-Fi off, hotspot off. Open the Sync tab. | LAN shows as off ("Turn on Wi-Fi or hotspot"), not as an error. |
| E2 | Another app holds port 52741 on A (e.g. run the app twice in a work profile). A visible. | Hosting still works on another port; the QR and mDNS carry that port; B syncs via the list or the QR. The gateway probe will not find it (expected: it only tries 52741). |
| E3 | VPN on A (any VPN app). A visible. | QR lists no `tun` address; sync over Wi-Fi still works. |
| E4 | A visible, then add a new group on A and invite B while the host screen is open. | B's list shows the new shared group within one refresh (no need to restart hosting). |
| E5 | Leave A visible over a 10-minute boundary (e.g. 10:09 to 10:11). | B still sees A as sharing "Goa trip" after the boundary (tokens rotate every 10 min and the advert updates in place). |
| E6 | A visible; B syncs; immediately close the app on A mid-transfer. | B fails cleanly; reopening A and syncing again completes; no duplicates. |
| E7 | Install the app on two fresh phones within the same minute, create a group on one and invite the other. Then A visible, B "Find nearby". | B lists A, sharing the group, on every transport (the advertised id is random per phone and window, not part of the device id). |
| E8 | Set B's clock 2 hours ahead (Settings, Date and time, manual). A visible, B "Find nearby"; then the same with B a day behind. | B still lists A as sharing "Goa trip" and syncs by tapping it. |
| E9 | One phone in 20+ groups (a few trips plus many friends). It is visible; a phone sharing one of those groups scans for an hour. | The shared group is shown the whole time, over LAN, Nearby and BLE. |
| E10 | During a large LAN sync from B to A, turn B's Wi-Fi off (A keeps a half-open connection). B taps Cancel, then syncs again over Bluetooth at once. | A accepts the retry right away (the stale session is replaced); no "busy". |
| E11 | Open `settleup://sync?v=1&h=203.0.113.7:52741&d=x&n=X` on a phone (e.g. from a note or a browser). | "That code isn't a Settle Up link."; nothing is dialed (no outgoing connection in a packet capture). |

---

## 3. Android permissions per API level

Settle Up asks for permissions only when the user starts a sync on that
transport (SPEC 8.10). LAN never needs a runtime permission on Android. The
table below is what the app is expected to ask for; record what each phone
actually showed.

| Transport | API 26-30 | API 31-32 | API 33-36 |
|---|---|---|---|
| LAN / hotspot | none | none | none |
| Nearby Connections | Location (while in use) | Nearby devices + Location | Nearby devices (Bluetooth + nearby Wi-Fi), no location |
| BLE | Location (while in use) | Nearby devices | Nearby devices |
| QR scan | Camera | Camera | Camera |

Also verify (SPEC 9.1):

| # | Check | API 31/32 phone | API 34+ phone |
|---|---|---|---|
| P1 | Fresh install, "Find nearby" with only LAN: no permission dialog at all. | | |
| P2 | Deny Nearby devices twice ("Don't ask again"). The Bluetooth row offers "Open settings", not another dialog. | | |
| P3 | Location services switched **off** on API ≤ 32: the Bluetooth row says the radio needs location on, instead of finding nothing silently. | | n/a |
| P4 | `BLUETOOTH_SCAN` is declared `neverForLocation`. Nearby Connections discovery finds the other phone. **If it finds nothing on API 31+**, record it here; the fix is to drop the flag and request location for nearby and ble on every API level (SPEC 9.1). | | |
| P5 | `adb shell dumpsys package app.settleup.settleup | grep permission`: `BLUETOOTH`, `BLUETOOTH_ADMIN` capped at 30, both location permissions capped at 32 after manifest merge. | | |
| P6 | Settings, Apps, Settle Up, Backup: app data is excluded (allowBackup off). | | |
| P7 | Tap a `settleup://join?...` link in a chat app: Settle Up opens on the join screen. | | |
| P8 | No usage metrics to Google (docs/PRIVACY.md). Release APK, Wi-Fi with internet, a traffic monitor such as PCAPdroid filtered to Settle Up. Scan an invite QR code, sync once, keep the app open 10 minutes, then lock the screen for an hour. Nothing goes to `firebaselogging-pa.googleapis.com` (or any internet host); only the other phone's LAN address appears. `adb logcat | grep -i transport` may show "Transport backend 'cct' is not registered": that is the expected drop. | | |

---

## 4. Bluetooth: Nearby Connections and BLE

Owned by WP-D2. Required runs (SPEC 11.3): Android to Android over Nearby,
Android to iOS over BLE, three-phone gossip over Bluetooth only. Turn
**Wi-Fi off** on every phone in this section (and keep mobile data off), so
the engine cannot quietly pick LAN, which it prefers over Bluetooth.

How the Bluetooth transports work (so failures can be placed). Logs are
under `settle_up.sync.nearby` and `settle_up.sync.ble`.

- **Nearby Connections** (Android only, kind `nearby`): service id
  `app.settleup.sync`, strategy `P2P_CLUSTER`. The advertised endpoint name
  is `2|<advert id>|<window tag>|<device name, 24 max>|<up to 24 tokens>`
  (SPEC 8.3: the advert id is random and changes every 10 minutes; no
  device id is advertised), so the scanner lists the phone and its shared
  groups without connecting. Both
  sides accept every connection automatically; the session handshake does
  the authentication. One frame is one BYTES payload (32 KiB max). Nearby
  may move the link from Bluetooth to Wi-Fi by itself during a sync; that
  is expected.
- **BLE GATT** (Android and iOS, kind `ble`): the visible phone is a GATT
  peripheral with service `82101e6c-f454-4ceb-86a8-5375a3b1a414` and three
  characteristics: INFO (read, who it is), RX (write) and TX (notify). The
  scanning phone is the central and always the initiator. For each new
  phone it connects briefly, reads INFO, disconnects and caches the result
  for 60 s. Tapping the row connects again, asks for MTU 517 (Android),
  subscribes to TX and starts the session. Frames travel in chunks of one
  ATT packet with a sequence number; a lost chunk ends the session (it
  never corrupts data). Only one BLE session runs at a time.
- On Android the BLE advertisement carries **no local name**:
  `bluetooth_low_energy` would rename the phone's Bluetooth adapter to the
  advertised name. iOS advertises the name `SU`. Scanners filter on the
  service UUID only, so both are found the same way.

### 4.1 Nearby Connections (Android to Android)

| # | Steps | Expected |
|---|---|---|
| N1 | A and B (Wi-Fi off, Bluetooth on). A: Sync tab, "Make visible". B: "Find nearby". | Permission dialogs as in section 3 the first time. Within 15 s B lists A by device name, sharing "Goa trip", with Nearby as a route. |
| N2 | B taps A. | Synced over Nearby (session screen names the transport). No connection prompt on A: the app accepts by itself. |
| N3 | Seed 500 expenses on A first, then sync from a fresh B. | Completes; both phones equal. Note the time it took in the log. |
| N4 | B keeps "Find nearby" open for 2 minutes while A stays visible. | A stays listed the whole time (re-emitted every 5 s; the engine drops a peer after 15 s of silence). |
| N5 | A stops being visible (leave the host screen). | A disappears from B's list within about 20 s. |
| N6 | During a 500-expense sync, walk B out of range (or turn its Bluetooth off). | Session fails with the partial "Nothing was lost" message; the next sync completes; no duplicates. |
| N7 | A visible over a 10-minute boundary (e.g. 10:09 to 10:11), B scanning. | A still shows as sharing "Goa trip" after the boundary. In logcat, A restarts its Nearby advertisement once (the name carries the new tokens); an open session is not interrupted. |
| N8 | A and B both visible and both scanning, both tap each other at the same moment. | One session runs and both phones show it as their sync (the phone with the lower device id serves the other one's connection). Neither says "Syncing with another phone"; both phones end equal. |
| N8b | Like N8, but A's Wi-Fi route hangs (A on a different Wi-Fi than B, so its LAN dial times out before Nearby is tried). | Both syncs end well, or at worst one says "busy: Starting its own sync". Never "Syncing with another phone" (SYNC-R2-02). |
| N8c | A in more than 24 groups (e.g. 30 friends added), B shares only an old group A has never synced. Wi-Fi off. | B lists A as "may share a group" with Sync, not Pair. Tapping Sync syncs the shared group. After that sync, B lists A as sharing that group in every later window (SYNC-R2-01). |
| N9 | A phone without Google Play services (or with it disabled), if available. | Hosting and finding still work over BLE; Nearby failures only show in logcat (`settle_up.sync.nearby`). Record what the Sync tab says for Nearby. |
| N10 | On the N9 phone: make it visible, stop, make it visible again, then "Find nearby". | In logcat (`settle_up.sync.nearby`) exactly one "Nearby is unavailable on this phone" with the API_UNAVAILABLE cause on the first try. After it Nearby reports unsupported and no further Nearby start calls are logged until the app restarts; BLE still works. |

### 4.2 BLE between two Android phones

Two Android phones prefer Nearby over BLE, so BLE runs between them only
when Nearby is not usable on one side (for example Google Play services
missing or disabled, see N9). Check that the session screen says BLE; if
no phone pair falls back to BLE, mark 4.2 as not run and rely on 4.3,
which always uses BLE.

| # | Steps | Expected |
|---|---|---|
| B1 | A visible, B scanning. | B lists A within 15 s. In logcat on B: one connect, one INFO read and a disconnect per new phone, then one re-read a minute while it stays visible (never a connect every few seconds). |
| B2 | B taps A. | Synced over BLE. Logcat on B shows the MTU after negotiation (usually 517 or 247 on Android pairs). |
| B3 | Seed 500 expenses on A, sync to a fresh B. | Completes; equal on both. Record the time: BLE is the slowest path, a minute or two is acceptable, more is a bug. |
| B4 | Keep B 5 to 8 m away (another room) during B3. | Either completes or fails with "Nothing was lost"; never a hang longer than the 20 s idle limit. |
| B5 | After any BLE test, open Android Settings, Bluetooth on A. | A's Bluetooth name is unchanged (not "SU"). |
| B6 | Turn Bluetooth off on A while B's list shows it. | A drops off B's list within about 20 s; A's Sync tab shows Bluetooth as off. |
| B7 | While A and B run a BLE session, phone C (also scanning) taps A. | C gets "busy" or "could not reach"; the A to B session is unaffected. |

### 4.3 BLE between Android and iPhone

| # | Steps | Expected |
|---|---|---|
| X1 | Fresh install on D (iPhone). D: "Find nearby". | iOS shows the Bluetooth prompt with "Settle Up uses Bluetooth to share expenses with friends' phones nearby, without internet." |
| X2 | Allow. A (Android) visible, D scanning. | D lists A within 15 s and syncs (D is the central, A the peripheral). |
| X3 | D visible ("Make visible"), A scanning. | A lists D within 15 s and syncs (A is the central and asks for MTU 517; D's MTU comes from iOS, typically 185). |
| X4 | X2 and X3 with 500 expenses seeded on the sending side. | Both complete; equal on both. Record both times. |
| X5 | D visible, then lock D's screen during a sync. | The session fails cleanly (no background modes in the MVP); the next sync with D unlocked completes. |
| X6 | iOS Settings, Settle Up, Bluetooth off. Open the Sync tab on D. | The Bluetooth row asks to allow Bluetooth in Settings; no crash. |
| X7 | D visible; A syncs, then A syncs again within 60 s. | The second time A lists D without a new INFO read in the log (cache), and the sync works. |

### 4.4 Three phones over Bluetooth only

| # | Steps | Expected |
|---|---|---|
| G1 | Wi-Fi off on A, B and D. Add an expense on A only. B syncs with A (Nearby or BLE), then D syncs with B (BLE). | D has A's expense without ever meeting A (gossip). |
| G2 | Then add one expense on each phone and sync D with A over BLE. | A and D equal; B gets the rest at its next sync. |

### 4.5 Things to watch and record

These behaviours could not be checked without radios. Write what you see
in the result log, with the phone models.

- **Nearby ordering:** the transport relies on Nearby delivering BYTES
  payloads in order. If sessions over Nearby fail with `authFailed` or a
  decrypt error while BLE and LAN work, report it: that would mean payloads
  arrived out of order.
- **Connect while scanning:** BLE probes and the BLE connect run while the
  scan continues. If Android phones often fail the first connect (status
  133 in logcat) but a retry works, report it.
- **iOS peripheral hang-up:** iOS cannot drop a connected central from the
  peripheral side. After D ends a session as the visible phone, check that
  A can sync with D again right away.
- **Notify flow control:** the peripheral waits for every notification and
  retries a full queue after 20 ms, up to 50 times. Look for
  `notify ... failed 50 times` in logs during big syncs.
- **Gradle:** `nearby_connections` 4.3.0 pins AGP 7.4.2 in its own build
  script. `flutter build apk --debug` succeeded on the Bluetooth branch
  (2026-11-09) with only a "migrate to Built-in Kotlin" warning for some
  plugins. If a later build fails on that plugin, record the error; the
  integrator vendors the plugin (SPEC 9.1).

---

## 5. Result log

| Date | Build (commit) | Phones | Section | Result | Notes / bug |
|---|---|---|---|---|---|
| | | | | | |
