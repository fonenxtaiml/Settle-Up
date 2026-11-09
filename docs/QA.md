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
| P5 | `adb shell dumpsys package app.settleup.settle_up | grep permission`: `BLUETOOTH`, `BLUETOOTH_ADMIN` capped at 30, both location permissions capped at 32 after manifest merge. | | |
| P6 | Settings, Apps, Settle Up, Backup: app data is excluded (allowBackup off). | | |
| P7 | Tap a `settleup://join?...` link in a chat app: Settle Up opens on the join screen. | | |

---

## 4. Bluetooth: Nearby Connections and BLE

Owned by WP-D2. Required runs (SPEC 11.3): Android to Android over Nearby,
Android to iOS over BLE, three-phone gossip over Bluetooth only.

---

## 5. Result log

| Date | Build (commit) | Phones | Section | Result | Notes / bug |
|---|---|---|---|---|---|
| | | | | | |
