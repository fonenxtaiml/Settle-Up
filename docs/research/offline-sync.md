# Settle Up: Offline Peer-to-Peer Sync Research and Design

Status: research complete, recommendation approved for Phase 1 (offline + LAN/hotspot + Bluetooth). Cloud sync is Phase 2.
Date: 2026-11-09. Package versions were checked on pub.dev on this date. They are relative to that day ("published N days ago"), so re-check before pinning.

---

## 0. TL;DR (Recommendation)

| Concern | Choice | Version (2026-11-09) | Why |
|---|---|---|---|
| Local DB | `drift` + `sqlite3` (build-hook bundled SQLite) | drift 2.35.4, sqlite3 3.9.1 | Very actively maintained, relational, transactional, reactive streams, migrations. Good for an op log plus materialized views. |
| IDs | UUIDv7 via `uuid` | 4.6.0 (RFC 9562 v6/v7/v8) | Globally unique with no coordination, time-sortable, and server-friendly. |
| Clock | Hybrid Logical Clock (own ~80-line implementation) | n/a | Causality-friendly LWW ordering that tolerates phone clock skew. |
| Delta exchange | Per-device monotonic counter plus a version vector per group | n/a | Exact "what are you missing" in one round trip. Works through relays. |
| Crypto | `cryptography` + `cryptography_flutter` | 2.9.0 / 2.3.4 | AES-256-GCM, HMAC-SHA256, HKDF, X25519, Ed25519. Flutter add-on uses OS crypto. |
| LAN / hotspot transport | `dart:io` `ServerSocket`/`Socket` (TCP) | SDK | Zero dependencies, fast (MB/s), works on Android and iOS, and works between Android and iOS. |
| LAN discovery | `bonsoir` (mDNS/DNS-SD `_settleup._tcp`) | 7.1.6 | Maintained (published ~2 weeks ago), Android/iOS/desktop. `nsd` 5.0.1 is an alternative. |
| Hotspot fallback | `network_info_plus` (gateway IP probe) + QR code with `ip:port` | 8.2.2 | mDNS is unreliable on hotspots. The hotspot host is the client's gateway. |
| Create a hotspot from the app (Android, optional) | `wifi_iot` (LocalOnlyHotspot) | 0.4.0 | The OS picks the SSID and password. Show them as a Wi-Fi QR code. |
| Bluetooth, cross-platform (Android and iOS) | `bluetooth_low_energy` (central and peripheral in one MIT plugin) | 6.2.1 | GATT server and client on Android, iOS, macOS, Windows. Good enough for op-log deltas (KBs). |
| Bluetooth bulk, Android to Android (optional fast path) | `nearby_connections` (Google Nearby Connections) | 4.3.0 | Handles BT/BLE discovery and upgrades to Wi-Fi automatically. Android only. |
| QR | `qr_flutter` / `mobile_scanner` | 4.1.0 / 7.5.0 | Pairing invites and connection hints. |
| Permissions | `permission_handler` (+ a small platform channel for `ACCESS_LOCAL_NETWORK` if it is not supported yet) | 13.0.2 | Android 12+ Nearby Devices group, Android 17 local network permission. |
| Wire format | Length-prefixed frames: `u32 len + u8 type + body`. Body is UTF-8 JSON, gzip for large batches. Encrypted with AES-GCM. BLE chunks each frame to MTU. | n/a | Easy to debug. MessagePack packages on pub.dev are stale (`messagepack` 0.2.1, 5 years old). |

**Transport priority at runtime:** (1) TCP over LAN/hotspot (discovered by mDNS, gateway probe, or QR). (2) Nearby Connections when both peers are Android. (3) BLE GATT as the always-works fallback (Android and iOS, no Wi-Fi needed).
All three carry the **same** encrypted frame protocol, so the sync engine does not know which transport it uses.

---

## 1. Transport research

### 1.1 Wi-Fi hotspot / same local network

**Transport:** plain TCP using `dart:io` `ServerSocket.bind(InternetAddress.anyIPv4, port)` on the "host" phone and `Socket.connect(ip, port)` on the "joiner". No plugin is needed. Throughput is several MB/s, which is far more than an expense log needs. It also carries receipt photos. This is the only transport that works natively and fast **between Android and iOS**. A lighter alternative is `HttpServer` with a WebSocket upgrade. Raw TCP with our own framing is simpler and has fewer moving parts.

**Discovery options (use all three, in order):**

1. **mDNS / DNS-SD** with `bonsoir` 7.1.6 (or `nsd` 5.0.1). The host advertises `_settleup._tcp` with TXT records `v=1`, `dev=<deviceId short>`, `port`. Do **not** put group ids in clear text; see 3.8 for blinded ids. The joiner browses and resolves.
   - iOS needs `NSLocalNetworkUsageDescription` and `NSBonjourServices = ["_settleup._tcp"]` in Info.plist. The system shows a "Local Network" prompt the first time.
   - Android: `NsdManager` is a system service and handles multicast itself. Acquiring `WifiManager.MulticastLock` (`CHANGE_WIFI_MULTICAST_STATE`) is still advisable, because multicast is heavily power-managed when the screen is off.
2. **Gateway probe (hotspot case).** When phone A runs a hotspot and phone B joins it, **A is B's default gateway**. B reads `NetworkInfo().getWifiGatewayIP()` (`network_info_plus` 8.2.2) and tries `gateway:<well-known port>` directly. This works even when mDNS does not. Typical gateways:
   - Android tethering: historically `192.168.43.1`. Newer Android versions (11+) randomize the subnet (`192.168.x.1`, `10.x.x.1`), so **never hard-code it**. Always read it at runtime.
   - iOS Personal Hotspot: `172.20.10.1`.
   - LocalOnlyHotspot: a random private subnet, also the gateway.
   On the **host** side (A), the app enumerates `NetworkInterface.list()` to show its own tethering IP (interfaces such as `ap0`, `swlan0`, `wlan1`, `bridge100` on iOS) in a QR code.
3. **QR code fallback.** The host shows a QR code containing `settleup://sync?h=<ip>:<port>&s=<sessionNonce>` (plus the Wi-Fi credentials when we created the hotspot). The joiner scans it with `mobile_scanner` and connects directly. This always works when IP routing works, and it is also how we pair (section 3.8).

**Hotspot specifics and gotchas:**

- mDNS on hotspots is **unreliable**. Multicast and broadcast are often filtered or power-saved on the device acting as the access point, and the NSD responder on some devices does not advertise on the tethering interface. Reports differ by vendor, so treat mDNS as "nice when it works". Gateway probe and QR are the robust path.
- Hotspot **client isolation** (clients cannot reach each other) exists on some carriers and devices. Host to client traffic always works. So the **hotspot host should be the TCP server**. With more than two phones, the host also acts as the sync hub. Sync is gossip, so ops relay naturally.
- **Android LocalOnlyHotspot** (via `wifi_iot` 0.4.0, `startLocalOnlyHotspot`, API 26+): it needs location permission, the OS generates the SSID and passphrase (show them as a `WIFI:T:WPA;S:<ssid>;P:<pass>;;` QR that phone cameras can join), and it has no internet. iOS cannot create a hotspot programmatically. The user turns on Personal Hotspot in Settings.
- Wi-Fi Direct (`flutter_p2p_connection` 3.0.3: Android only, unverified uploader, 15 months old). It is not needed, because the LocalOnlyHotspot + TCP path covers the same case and also works with iOS clients.
- **Android 17 Local Network Protection (important).** Apps that **target SDK 37** (Android 17) are blocked by default from **all** LAN traffic: outgoing and incoming TCP, UDP unicast/multicast, mDNS, and `NsdManager`. This includes `dart:io` sockets (Flutter issue #184859). The app must declare and request the runtime permission **`ACCESS_LOCAL_NETWORK`**. It is in the **NEARBY_DEVICES** group, so it is pre-granted if the user already granted Bluetooth "Nearby devices" permissions. Apps targeting SDK 36 or lower get an implicit grant and must **not** request it. Plan: request Nearby Devices permissions (BLUETOOTH_SCAN/CONNECT/ADVERTISE, NEARBY_WIFI_DEVICES, and ACCESS_LOCAL_NETWORK once we target 37) together on the "Sync nearby" screen, with a rationale. Blocked TCP shows up as a **timeout** and blocked UDP as **EPERM**. Surface a "grant Nearby devices permission" hint on timeouts. The alternative is the system NSD picker (`DiscoveryRequest.FLAG_SHOW_PICKER`), which grants access only to the chosen device. That would need a small Kotlin channel and is worth evaluating later.

### 1.2 Bluetooth

#### Options evaluated

| Package | Version / age | Platforms | Verdict |
|---|---|---|---|
| `nearby_connections` | 4.3.0, ~20 months old, verified publisher | **Android only** | **Use as an optional Android-to-Android path.** Google Play Services Nearby Connections does BT/BLE/Wi-Fi discovery and upgrades the connection automatically to Wi-Fi (hotspot/Direct/LAN) for high throughput. Strategies: `P2P_CLUSTER` (M-to-N), `P2P_STAR`, `P2P_POINT_TO_POINT` (fastest). BYTES payloads are capped at about 32 KB (`MAX_BYTES_DATA_SIZE`; I could not re-verify this, the Google docs host was unreachable), so chunk frames or use STREAM payloads. The plugin is a thin wrapper over a stable Google API. Old but workable, and could be forked if needed. |
| `flutter_nearby_connections` | 1.1.2, ~2 years old | Android (Nearby) + iOS (Multipeer) | Do not use. Stale. Android and iOS **cannot talk to each other** (different stacks). |
| `flutter_nearby_connections_plus` | 1.2.2, ~16 months old, 3 likes | same | Same interop problem. Small fork. |
| `nearby_service` | 0.2.1, ~13 months old | Android Wi-Fi Direct, iOS Multipeer | States it does **not** support Android to iOS. |
| `nearby_cross` | 1.0.2, ~2 years old, unverified | Android + iOS via Google Nearby Swift | Google's Nearby Swift port supports **Wi-Fi LAN only** on iOS (no BT), so it gives no advantage over our own TCP path. |
| `flutter_blue_plus` | 2.3.15, published 3 days ago | Android/iOS/macOS/Linux/Web | **Central only.** Its **license requires a paid commercial license for for-profit use.** Pair with `flutter_ble_peripheral` 3.2.0 (GATT server with TX/RX characteristics, active) if chosen. |
| `ble_peripheral` | 2.4.0, ~23 months old | Android/iOS/macOS/Windows | Full GATT server (services, notify, read/write requests, MTU callbacks). Less active. |
| **`bluetooth_low_energy`** | **6.2.1** (~9 months old; 7.0.0-dev in progress), verified, MIT | Android/iOS/macOS/Windows (+Linux central) | **Recommended.** One plugin provides both `CentralManager` and `PeripheralManager` (GATT server). Every phone can act as either role, which is exactly what symmetric P2P sync needs. |
| `flutter_classic_bluetooth` | 1.7.2, active | RFCOMM server/client on Android. iOS supports MFi accessories only. | Do not use for v1. Classic Bluetooth SPP gives higher throughput Android to Android, but Nearby already covers that case, and it cannot reach iPhones. |

#### BLE throughput and why it is only the fallback

- ATT default MTU is 23 bytes (20 bytes of payload). Android can request up to 517 (512-byte attribute values). `flutter_blue_plus` asks for 512 by default. iOS negotiates automatically, typically 135 to 255 (often 185). Payload per write or notify is `MTU - 3`.
- Real-world GATT throughput on phones is about **5 to 100 KB/s**, depending on connection interval, write-with versus without response, 2M PHY, and vendor. Notifications and write-without-response are fastest, but they need app-level flow control.
- An expense op is about 300 to 700 bytes of JSON. Gzip shrinks a batch about 4 to 6 times. A typical delta (tens of ops) is a few KB, which takes **under a second**. A cold sync of a 2,000-expense group is about 1 MB raw and about 200 KB gzipped, which takes **2 to 40 s** over BLE. That is acceptable, with a progress bar. **Receipt images are not sent over BLE** (they are LAN only, see 3.10).
- For bulk transfer, classic Bluetooth RFCOMM (about 100 to 250 KB/s), and especially Nearby Connections' automatic **upgrade to Wi-Fi** (MB/s), are far better. That is why Nearby is the preferred "Bluetooth" path when both peers are Android, and BLE GATT is the universal fallback, mainly for iPhone to Android with no shared Wi-Fi.

#### BLE GATT design for Settle Up

- One custom service `SETTLEUP_SVC_UUID` with two characteristics:
  - `RX` (write / write-without-response): central to peripheral.
  - `TX` (notify): peripheral to central.
- The advertisement carries the service UUID and a short rotating token (8 bytes, `HMAC(groupKey, epochMinute)` truncated). Scanners can then recognise "a member of one of my groups" without exposing group ids.
- After connecting: request MTU 512 (Android). Read the effective MTU on both sides. Subscribe to TX.
- **Chunking:** every encrypted protocol frame is split into chunks of `(mtu - 3) - 2` bytes, each with a 2-byte header: `flags(1)` = FIRST|LAST bits, plus `seq(1)` mod 256. The receiver reassembles until LAST, then passes the frame up.
- **Flow control:** use write-**with**-response for central to peripheral (reliable, OS-paced), or windowed write-without-response with a credit frame every 16 chunks. For notify (peripheral to central), the peripheral waits for the "ready to update subscribers" callback (`isReadyToUpdateSubscribers` on iOS, `onNotificationSent` on Android) before sending the next chunk.
- Max frame size on BLE: 16 KB (`OPS` batches are sized for that).

---

## 2. Local database choice

| Option | Status (2026-11-09) | Fit |
|---|---|---|
| **drift + sqlite3** | drift 2.35.4 published 15 h ago. sqlite3 3.9.1 published 24 h ago and now **bundles SQLite through Dart build hooks**. (`sqlite3_flutter_libs` is EOL at 0.6.0+eol, so do not add it.) | **Recommended.** SQL is a natural fit for an op log table, indexes on `(group_id, device_id, counter)`, transactional apply, aggregation queries for balances, reactive `watch()` queries for UI, and typed migrations. The same SQL schema maps directly onto Postgres for the cloud phase. |
| isar | Upstream `isar` stable is still 3.1.0+1 from **about 3 years ago**, and 4.0.0-dev has not shipped. The original author effectively stepped away. A community fork, `isar_community` 3.4.1, is maintained. | Avoid. Upstream is abandoned, and the fork is a single maintainer group doing bug fixes only. NoSQL is also a poorer fit for ledger aggregation. |
| hive / hive_ce | `hive` 2.2.3 is 4 years old and the v4 dev has stalled. `hive_ce` 2.23.2 is active. | Key-value only. Fine for settings, but poor for queries, joins, and transactional multi-row apply. Not the primary store. |

Use `shared_preferences` (or a drift `kv` table) for device settings. Use `flutter_secure_storage` for group keys and the device private key.

---

## 3. Sync design

### 3.1 Principles

1. **Local-first:** every write goes to the local DB immediately. Sync is opportunistic.
2. **Op-based replication.** Each user action becomes an immutable, append-only **operation** with a global id. Peers exchange the ops they are missing. Materialized tables (expenses, members, and so on) are a deterministic function of the op set.
3. **Merge is commutative, associative, and idempotent.** Receiving the same op twice, or ops in any order, converges to the same state (a state-based CRDT made of LWW registers built from ops).
4. **Never sync derived data.** Balances, "who owes whom", and simplified debts are always **computed locally** from expenses and settlements. This removes a whole class of conflicts.
5. **Group = sync scope = trust scope.** You only receive ops for groups you are a member of (you hold the group key).

### 3.2 Identifiers

- `deviceId`: UUIDv7, generated on first launch, stored permanently.
- Every entity id (group, member, expense, settlement, comment) and every `opId` is a **UUIDv7** (`uuid` 4.6.0: `Uuid().v7()`). UUIDv7 is time-ordered, so B-tree inserts stay index-friendly and the ids work unchanged in Postgres later.
- `member` is distinct from `device`. A person (member) may have zero devices (a friend without the app) or several. A member can optionally be linked to a `userId` later, in the cloud phase.

### 3.3 Hybrid Logical Clock (HLC)

Per device, the state is `(l: int64 physicalMillis, c: int16 counter)`.

- **Local event / send:** `l' = max(l, now)`. If `l' == l`, then `c++`, else `c = 0`.
- **Receive op with (lm, cm):** `l' = max(l, lm, now)`. Then `c` is: `max(c, cm)+1` if all three are equal, `c+1` if `l'==l`, `cm+1` if `l'==lm`, else `0`.
- **Total order / tiebreak:** `(l, c, deviceId)`. Encode as a fixed-width sortable string, for example `"%013d-%04x-%s"`, or as two integer columns plus device id.
- **Skew guard:** if a received `lm` is more than 24 h ahead of `now`, still accept the op (it is data), but **do not** advance our clock beyond `now + 1 min`. Log a "peer clock skew" diagnostic. This stops one phone with a wrong date from poisoning everyone's clock.

### 3.4 Operation log (drift table `ops`)

```text
ops(
  op_id        TEXT PRIMARY KEY,    -- UUIDv7
  group_id     TEXT NOT NULL,
  device_id    TEXT NOT NULL,       -- author device
  counter      INTEGER NOT NULL,    -- per-(device, group) monotonic 1,2,3...
  hlc          TEXT NOT NULL,       -- sortable HLC string
  entity_type  TEXT NOT NULL,       -- group|member|expense|settlement|comment
  entity_id    TEXT NOT NULL,
  kind         TEXT NOT NULL,       -- create|set|delete|restore|merge_member
  payload      TEXT NOT NULL,       -- JSON map of field -> value (only changed fields)
  schema_ver   INTEGER NOT NULL,
  author_sig   BLOB NULL,           -- optional Ed25519 signature (phase 2)
  received_at  INTEGER NOT NULL,    -- local bookkeeping, not synced
  UNIQUE(group_id, device_id, counter)
)
INDEX ops_by_entity(entity_type, entity_id)
version_vector(group_id, device_id, max_counter, PRIMARY KEY(group_id, device_id))
field_clock(entity_id, field, hlc, op_id, PRIMARY KEY(entity_id, field))
```

- `counter` is per **(author device, group)** and strictly contiguous. That makes the version vector an exact summary: "I have all ops from device D in group G with counter at most N".
- Ops arriving out of order (gaps) are stored but **not counted** in the VV until the gap is filled. The VV advances only over a contiguous prefix. Gaps cannot normally happen, because we send ops per device in counter order. The rule exists for robustness against interrupted transfers.
- Applying an op in one drift transaction: `INSERT OR IGNORE INTO ops`. If inserted, then for each field in the payload compare against `field_clock`. If `op.hlc > existing.hlc`, write the field to the materialized table and update `field_clock`. Advance the VV. This is idempotent and order-independent.
- **Compaction (later):** once every known member device's VV has passed an op, and a newer op superseded it for all of its fields, it can be pruned. For Phase 1 keep everything (ops are small). It also gives a complete audit history, which matches Splitwise's activity feed.

### 3.5 LWW granularity: per field, with atomic "money blocks"

- **Per-field LWW** for independent scalar fields: `expense.description`, `notes`, `category`, `date`, `group.name`, `group.currency`, `member.displayName`, and so on. Two people editing different fields of the same expense offline both keep their changes.
- **Atomic register for the money block.** `amount_minor`, `currency`, `payers[]` (who paid how much), `split_type`, and `shares[]` (per-member owed amounts or weights) are written **together as one field `money`**, with one HLC. Merging "amount from A" with "split from B" would produce an expense whose shares do not sum to the total. So the money block is LWW as a unit, and the losing version stays in the op log and is shown in the expense history.
- Amounts are **integer minor units** (cents/paise) plus an ISO-4217 code. Never use doubles. Share rounding is deterministic: the remainder goes to members in a stable order, by member id. Every device then computes identical shares from `split_type` + weights. Store the computed shares in the op anyway, so later rule changes do not rewrite history.

### 3.6 Deletes, tombstones, restore

- Delete = op `kind=delete`, which sets field `deleted_at` (LWW register, HLC). The row stays as a **tombstone**. Lists hide it, and balances exclude it.
- Edits do not touch `deleted_at`. So a concurrent "edit vs delete" resolves to **deleted**, and the edit is preserved underneath. "Restore" (`kind=restore`, `deleted_at=null` with a newer HLC) brings the expense back with the latest edits. This mirrors Splitwise's "restore deleted expense" feature.
- Tombstones are never physically removed in Phase 1. Otherwise a stale peer would resurrect the row.

### 3.7 Expense-specific conflict cases

| Case | Resolution |
|---|---|
| Two devices edit the amount offline | Money-block LWW (later HLC wins). The activity feed shows "Rahul's change to ₹1,200 replaced Asha's ₹1,150" and the user can revert in one tap. |
| A edits the description, B edits the amount | Both kept (different fields). |
| Edit vs delete | Delete wins, the edit is kept underneath, restore is available (3.6). |
| Two devices both add "Bob" offline (duplicate member) | Both members exist (different UUIDv7). The UI offers **"Merge members"**, which writes op `merge_member{from, into}` (LWW on `from.merged_into`). Balance computation maps `from` to `into` at read time, so it is order-independent and no historical expenses are rewritten. |
| Member removed while someone adds an expense involving them offline | Removal is a tombstone flag on the member. The expense still references the member. Balances remain correct, and the UI shows "(removed) Bob owes ₹200" and blocks removal while the balance is not zero, where it can. |
| Settlement recorded twice ("I paid you back" on two phones) | These are distinct entities. Show a "possible duplicate" hint (same payer, payee, and amount within 24 h). The user deletes one. No automatic dedupe, because money must not silently disappear. |
| Group currency changed concurrently | Per-field LWW. Each expense carries its own currency, so nothing breaks. |
| Clock-skewed phone | HLC plus skew guard (3.3). The tiebreak is deterministic, so all peers converge even if the "winner" is surprising. Show the history. |
| Schema version mismatch | Ops with `schema_ver` higher than supported are stored and relayed but not applied. They are applied after an app update. Unknown fields are preserved. |

### 3.8 Pairing and trust

- **Group creation:** `groupId = UUIDv7`, and `groupKey = 32 random bytes` (`Random.secure()`), stored in `flutter_secure_storage`.
- **Invite QR** (`qr_flutter`; scanned with `mobile_scanner`):
  `settleup://join?v=1&g=<groupId>&k=<base64url(groupKey)>&n=<groupName>&m=<inviterMemberId>&h=<ip:port optional>`
  Anyone holding the QR code is a member. Treat it like a password: show it full screen with a short timeout, and use "share link" only on explicit action. Phase 2 can add one-time invite tokens validated by the server.
- **Session handshake** (Noise NNpsk0-like, per connection, transport-agnostic):
  1. Both peers generate ephemeral X25519 keys and exchange `HELLO{proto, deviceId, ephPub, nonce, blindedGroups[]}`, where `blindedGroup = HMAC-SHA256(groupKey, "settleup-gid" || nonce)[0..16]`. A passive listener cannot learn which groups you are in. The receiver computes the same value for each of its groups to find the intersection.
  2. `sessionKey = HKDF-SHA256(ikm = X25519(ephA, ephB) || groupKey, salt = nonceA || nonceB, info = "settleup-sync-v1" || groupId)`. This gives one session key per shared group, with forward secrecy from the ephemeral DH and authentication from the PSK.
  3. Each side sends `AUTH{mac = HMAC(sessionKey, transcriptHash)}`. On a mismatch, drop the connection.
  4. All further frames use **AES-256-GCM** with a 96-bit nonce = `direction(1 byte) || 0x000000 || counter(8 bytes)`. Never reuse a nonce. Rekey after 2^32 frames.
- Library: `cryptography` 2.9.0 (`X25519`, `Hkdf`, `Hmac.sha256()`, `AesGcm.with256bits()`, `Ed25519`) with `cryptography_flutter` 2.3.4 for native speed.
- **Authorship (Phase 2):** each device has an Ed25519 key pair. The public key is announced in a `device_joined` op. Ops are signed over `(opId, groupId, deviceId, counter, hlc, payload)`. A relayed op, or one stored on the server, then cannot be forged by another member or by the server. Phase 1 can skip this, because group members are mutually trusted friends. Reserve the `author_sig` column now.
- **Member removal / key rotation (Phase 2):** generate a new group key and distribute it to the remaining devices, encrypted per device (X25519 to each device's static key). The removed device keeps the history it already had.

### 3.9 Transport-agnostic protocol (v1)

**Framing** (the same on every transport):

```text
plain frame   := type:u8 | flags:u8 | body
flags bit0    := body is gzip-compressed
wire frame    := len:u32be | nonce:12 | AES-GCM(ciphertext of plain frame) | tag:16
(HELLO/AUTH are sent unencrypted: len:u32be | plain frame)
BLE           := wire frame split into chunks [flags:u8 FIRST|LAST][seq:u8][bytes ≤ MTU-5]
Nearby BYTES  := wire frame split into ≤ 32 KB payloads (or one STREAM payload)
TCP           := wire frames back-to-back on the socket
Max frame     := 1 MB on TCP/Nearby, 16 KB on BLE (negotiated in HELLO: maxFrame)
```

The body is canonical UTF-8 JSON. Use gzip (`dart:io` `gzip`) when the body is over 1 KB. MessagePack can be swapped in later behind the `flags` byte, with no protocol version bump.

**Messages:**

| Type | Body | Notes |
|---|---|---|
| `HELLO` | `{proto:1, minProto:1, deviceId, deviceName, app, ephPub, nonce, blindedGroups[], maxFrame, transport}` | Both sides send it at the same time. |
| `AUTH` | `{groups:[groupId], mac}` | Confirms the shared groups and key possession. |
| `VV` | `{groupId, vv:{deviceId: maxCounter}}` | One per shared group. |
| `OPS` | `{groupId, batch:int, ops:[op...], more:bool}` | The sender computes the ops where `op.counter > peerVV[op.device_id]` (missing devices count as 0), sorted by `(device_id, counter)`. Batches are sized to `maxFrame`. **Includes ops authored by third devices** (gossip relay). |
| `ACK` | `{groupId, batch, vv}` | Sent after the batch is committed in a DB transaction. Gives resumable progress. |
| `DONE` | `{groupId}` | No more ops from me for this group. |
| `BLOB_REQ` / `BLOB` | `{sha256}` / chunked bytes | Receipt images, TCP/Nearby only. |
| `PING` / `PONG` | `{}` | Keepalive on long BLE sessions. |
| `ERROR` | `{code, msg}` | e.g. `proto_unsupported`, `auth_failed`, `too_large`. |
| `BYE` | `{}` | Both sides sent `DONE` for all groups. Close the connection. |

**Flow:**

```text
A                                   B
HELLO  ───────────────────────────►
       ◄─────────────────────────── HELLO
AUTH   ───────────────────────────►            (derive session keys)
       ◄─────────────────────────── AUTH
VV(g)  ───────────────────────────►
       ◄─────────────────────────── VV(g)
OPS(g,1..n) ──────────────────────►            B applies in a txn → ACK
       ◄─────────────────────────── ACK(g,1..n)
       ◄─────────────────────────── OPS(g,1..m) (concurrently, full duplex)
ACK(g,1..m) ──────────────────────►
DONE(g) ◄────────────────────────► DONE(g)
BYE    ◄────────────────────────► BYE
```

- Full duplex on TCP and Nearby. On BLE, half duplex works too. The protocol does not depend on interleaving.
- If the connection drops, nothing is lost. The next session's VV exchange restarts from the committed state.
- **Live mode:** if the connection stays open (both phones are on the "Sync" screen), new local ops are pushed immediately as `OPS` frames. The UI shows changes "instantly" on the other phone.
- Three or more phones: any topology works (star around the hotspot host, chain, repeated pairs). Gossip relay plus VVs guarantee convergence.

### 3.10 Attachments (receipts)

Content-addressed blobs: `sha256` is stored in the expense's `receipt` field. Blob bytes are fetched lazily with `BLOB_REQ` over TCP or Nearby only. Over BLE, only the reference syncs, and the UI shows "photo available when on Wi-Fi with Asha". In Phase 2 they go to object storage.

### 3.11 Cloud readiness (Phase 2)

Nothing in the design is P2P-specific:
- The server is "just another peer" with its own VV per group. Endpoints: `POST /groups/{id}/ops` (batch upload, idempotent on `op_id`), `GET /groups/{id}/ops?vv=...` (delta download), and a WebSocket for live push. The same frame protocol can also run over a WebSocket.
- UUIDv7 ids, HLC strings, integer money, and per-field clocks map 1:1 onto Postgres tables (`ops`, `version_vector`).
- Optional end-to-end encryption: the server stores ops encrypted with the group key (envelope `{opId, groupId, deviceId, counter, ciphertext}`). It can still compute VVs from the clear metadata while being unable to read expenses.
- Ed25519 author signatures (3.8) stop the server from forging ops.
- Account linking: map `member` to `userId` with a `link_member` op.

---

## 4. Module layout (proposed)

```text
lib/sync/
  hlc.dart                  // HLC + encode/compare
  op.dart                   // Op model, JSON (de)serialization, canonical form
  op_applier.dart           // idempotent LWW apply in drift txn
  version_vector.dart
  protocol/
    frames.dart             // framing, gzip flag, msg types
    session.dart            // handshake, AES-GCM, state machine (transport-agnostic)
    sync_engine.dart        // VV diff, batching, ACK, live push
  transport/
    transport.dart          // abstract: Stream<Uint8List> incoming; send(Uint8List); close()
    tcp_transport.dart      // dart:io Socket/ServerSocket
    lan_discovery.dart      // bonsoir + gateway probe + interface IPs
    ble_transport.dart      // bluetooth_low_energy central/peripheral + chunking
    nearby_transport.dart   // nearby_connections (Android only)
  pairing/
    invite_qr.dart          // settleup://join encode/decode
lib/data/                   // drift database, tables, DAOs, balance computation
```

The `Transport` interface is simply a reliable, ordered byte-frame pipe. BLE and Nearby adapters handle chunking and reassembly internally, so `session.dart` is unit-testable with an in-memory pair of transports. Merge convergence can then be property-tested: random ops, random delivery orders, assert identical DB state.

---

## 5. Platform manifest checklist

**Android (`AndroidManifest.xml`):** `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `NEARBY_WIFI_DEVICES` (`usesPermissionFlags="neverForLocation"`), `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`, legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` (`maxSdkVersion=30`), `ACCESS_FINE_LOCATION` (needed by Nearby Connections, LocalOnlyHotspot, and BLE scanning on API ≤30), `CAMERA` (QR), and `ACCESS_LOCAL_NETWORK` **only once targetSdk ≥ 37**. Foreground service if sync must continue in the background (Phase 2).

**iOS (`Info.plist`):** `NSLocalNetworkUsageDescription`, `NSBonjourServices: [_settleup._tcp]`, `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`, and optionally `UIBackgroundModes: bluetooth-central, bluetooth-peripheral` (background BLE is heavily throttled, so foreground sync is assumed).

---

## 6. Rejected / deferred

- **Isar** (abandoned upstream), **Hive** (KV only), **Realm** (Atlas Device Sync was deprecated by MongoDB, and the Flutter SDK's future is uncertain).
- **Full CRDT libraries** (e.g. Automerge/Yjs ports): overkill. Our data are records of LWW registers, which a ~300-line op applier handles with full control over money semantics.
- **Multipeer-only / Wi-Fi Direct-only plugins**: no Android-to-iOS interop.
- **Classic Bluetooth RFCOMM**: Android only. Nearby covers Android-to-Android bulk transfer better.
- **`flutter_blue_plus`**: technically excellent, but central-only and commercially licensed for for-profit apps. Keep it as an alternative if licensing is acceptable.

## 7. Open items to verify during implementation

- Whether `permission_handler` 13.x exposes `ACCESS_LOCAL_NETWORK`. If not, add a 20-line Kotlin method channel. Keep `targetSdk` at 36 until verified.
- The behaviour of `bonsoir` advertising on the tethering interface on Samsung/Pixel/Xiaomi hotspot hosts (expected to be flaky; the gateway probe covers it).
- `bluetooth_low_energy` 7.0 (in dev) API changes. Pin `^6.2.1`.
- The Nearby Connections bytes payload cap (≈32 KB; re-verify on developers.google.com, which was unreachable from the research sandbox).

## Sources

- pub.dev package pages (checked 2026-11-09): drift, sqlite3, sqlite3_flutter_libs, isar, isar_community, hive, hive_ce, uuid, cryptography, bonsoir, nsd, network_info_plus, wifi_iot, flutter_p2p_connection, nearby_connections, flutter_nearby_connections, flutter_nearby_connections_plus, nearby_service, nearby_cross, flutter_blue_plus, ble_peripheral, flutter_ble_peripheral, bluetooth_low_energy, flutter_classic_bluetooth, qr_flutter, mobile_scanner, messagepack, permission_handler.
- [Android local network permission](https://developer.android.com/privacy-and-security/local-network-permission)
- [Behavior changes: apps targeting Android 17](https://developer.android.com/about/versions/17/behavior-changes-17)
- [Flutter issue #184859: Android 17 local network permission breaks dart:io sockets](https://github.com/flutter/flutter/issues/184859)
- [Google Nearby Connections Swift get-started](https://developers.google.com/nearby/connections/swift/get-started) and the google/nearby repository (iOS supports the Wi-Fi LAN medium only)
- [chainfire: Android UDP broadcast and multicast](https://chainfire.eu/articles/742/_dev_Android_Datagrams_UDP_Broadcast_and_Multicast_.) and community reports (KDE Connect, Syncthing forum) on unreliable multicast on hotspots
- Kulkarni et al., "Logical Physical Clocks and Consistent Snapshots in Globally Distributed Databases" (HLC), and RFC 9562 (UUIDv7)
