# Settle Up privacy policy

Effective 9 November 2026. Applies to Settle Up 1.0.0 and later for Android.

Settle Up is an expense-splitting app that works without the internet.
There is no Settle Up account, no Settle Up server and no cloud copy of
your data. Everything you enter stays on your phone, and it goes to
another phone only when you sync with a friend who is in the same group.

## In short

- No account, no sign-up, no email address or phone number.
- No analytics, no advertising, no crash reporting, no tracking.
- Your groups, expenses and payments are stored only on your phone.
- Sync goes directly from phone to phone, encrypted, and only for the
  groups both phones are members of.
- The developer receives nothing: we cannot see, recover or delete your
  data, because it never reaches us.

## What the app stores on your phone

| Data | Where | Why |
| --- | --- | --- |
| Your name and home currency | App database | Shown to the people in your groups and used as the default currency. |
| Groups, members, expenses, payments, notes and their edit history | App database | The ledger itself. |
| Group keys | Android Keystore-backed secure storage | Encrypting sync and proving membership of a group. |
| This phone's name and a random device id | App database | Telling phones apart during sync. |
| Settings (theme, default split, vibration) | App database | Your preferences. |

The app database is a SQLite file in the app's private storage, which
other apps cannot read. Cloud backup and the device-to-device transfer to
a new phone are switched off, so Android does not copy this data to
Google Drive or to another phone.

## What leaves your phone, and when

**When you sync.** Only when you sync, with the app open, and only to
phones nearby. Settle Up connects directly to the other phone over your Wi-Fi
network or hotspot, over Bluetooth, or through Nearby Connections. It sends
only the groups that both phones are members of. All of it is encrypted
with AES-256-GCM using keys that only members of those groups hold.

While the app is looking for phones or waiting for one (the Sync screen
and its QR code screen), nearby devices on the same Wi-Fi network or
within Bluetooth range can see:

- the phone name you chose in Settings (for example "Pixel 8"),
- a random id that changes every 10 minutes and at every app start. It is
  not derived from this phone's device id, so it cannot be used to
  recognise the phone from one window to the next,
- short codes that change every 10 minutes and mean something only to
  phones that hold the same group key.

Nothing that stays the same, such as the device id, is advertised. They
cannot see group names, members or amounts.

When another phone connects to sync, the two phones first exchange their
names and device ids, unencrypted, to check whether they share a group.
Everything after that is encrypted, and the connection is closed if they
share none.

**When you invite someone.** An invite QR code or link contains the group
id, the group name, its currency, your phone's name and the group key.
It can also carry this phone's address on the local network and its
device id, so that the first sync starts at once.
Anyone who has it can join the group and see and add expenses. The QR code
hides itself after 2 minutes and is kept out of screenshots; sharing the
link is a separate step that warns you first.

**When you export.** "Export as CSV" creates a file with a group's
expenses and opens Android's share sheet. Where it goes is your choice.

Nothing else is sent. The app does not use the internet: the Internet
permission is required by Android for the local Wi-Fi connection between
two phones, and the app opens no connection to any server.

## Permissions

| Permission | Used for | When it is asked |
| --- | --- | --- |
| Nearby devices (Bluetooth scan, connect, advertise) | Finding a friend's phone and syncing over Bluetooth or Nearby Connections. | On the Sync screen, when a Bluetooth sync needs it. |
| Nearby Wi-Fi devices (Android 13 and later) | Nearby Connections over Wi-Fi between two phones. | With Nearby devices. |
| Location (Android 12L and older only) | On those versions Android requires location permission for any Bluetooth or Wi-Fi scan. The app never reads your location, has no map and does not use GPS. The permission does not exist for the app on Android 13 and later. | On the Sync screen, when a Bluetooth sync needs it. |
| Camera | Scanning a friend's invite or connect QR code. Frames are decoded on the phone and are never saved or sent. | When you open the QR scanner. |
| Internet, network state, Wi-Fi state, Wi-Fi multicast | The local Wi-Fi or hotspot connection between two phones and finding them on the network (mDNS). | Granted at install; no prompt. |

You can refuse any of these. Sync over the other ways keeps working, and
the rest of the app works without any permission.

## Third-party components

- **QR scanner (Google ML Kit barcode scanning).** Settle Up uses the
  bundled ML Kit barcode model through the `mobile_scanner` library, so
  codes are decoded on the phone with no network. ML Kit can also send
  anonymous usage and performance metrics to Google. Settle Up removes the
  component that would upload them (the Firebase data transport "cct"
  backend), so those metrics are dropped on the phone and never sent.
- **Nearby Connections (Google Play services).** When you sync with
  Nearby Connections, the connection between the two phones is set up by
  Google Play services on your phone. The data goes directly between the
  phones and is encrypted by Settle Up before Play services carries it.
  Google Play services itself is covered by
  [Google's privacy policy](https://policies.google.com/privacy).
- **Fonts** are bundled with the app and are never downloaded.

## Deleting your data

- **An expense or a group:** delete it in the app. The deletion reaches
  the other members the next time you sync, and their phones stop counting
  it too. A deleted expense stays in the group's Deleted list, where it
  can be restored.
- **Everything on this phone:** Android Settings, Apps, Settle Up,
  Storage, Clear storage; or uninstall the app. This removes the database,
  the group keys and your settings from this phone. It cannot be undone,
  and because there is no backup we cannot restore it.
- **Copies on friends' phones:** a group you synced also lives on the
  phones of its other members. Uninstalling on your phone does not remove
  it from theirs. Ask them to delete the group or clear the app.

## Children

Settle Up is not directed at children and does not knowingly collect any
data from anyone, of any age.

## Changes and contact

If this policy changes, the new version is published at the same address
with a new effective date, and the release notes say what changed.

Questions: open an issue at <https://github.com/fonenxtaiml/settle-up/issues>.
