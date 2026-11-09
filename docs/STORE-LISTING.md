# Google Play store listing

Text and answers for the Play Console, for Settle Up 1.0.0
(`app.settleup.settleup`). Keep it in step with [PRIVACY.md](PRIVACY.md):
if one changes, check the other.

## Main store listing

**App name** (30 characters max)

> Settle Up: offline bill split

**Short description** (80 characters max)

> Split bills with friends and sync phone to phone. No internet, no account.

**Full description** (4000 characters max)

> Settle Up keeps track of who paid what on trips, in shared homes and
> between friends, and works with no internet at all.
>
> Add an expense, choose who paid and how to split it, and Settle Up shows
> who owes whom. When you meet, put two phones together and sync: the
> group's expenses go straight from one phone to the other over Wi-Fi, a
> hotspot or Bluetooth. No server sits in between, and nobody needs an
> account.
>
> Splitting
> - Split equally, by exact amounts, by percent, by shares, or equally with
>   adjustments. Remainders are rounded fairly and always add up.
> - Several people can pay for one expense.
> - Balances per group, per friend and overall, in each currency.
> - Simplify debts to the fewest payments, or see who owes whom directly.
> - Record a payment in cash, by bank transfer or UPI, in part or in full.
>
> Syncing without internet
> - Wi-Fi or a phone's hotspot: one phone shows a QR code, the other scans
>   it.
> - Bluetooth and Nearby Connections when there is no Wi-Fi.
> - Only the groups both phones share are exchanged, encrypted end to end
>   with keys only group members hold.
> - Edits made on different phones merge, and the history shows who
>   changed what.
>
> Private by design
> - Your data stays on your phones. No account, no ads, no analytics and
>   no tracking.
> - Invite friends to a group with a QR code.
> - Export a group as CSV whenever you like.
>
> Light and dark themes, large text support and screen reader labels
> throughout.

**Category:** Finance. **Tags:** Budgeting, Money management.

**Contact email:** the developer account's support address.
**Website:** <https://github.com/fonenxtaiml/settle-up>

**Privacy policy URL:** the published `docs/PRIVACY.md`, for example
<https://github.com/fonenxtaiml/settle-up/blob/main/docs/PRIVACY.md>
once `main` holds the release. Play needs a public URL that opens without
a sign-in: make the repository public, or publish the same text on a
public page (for example GitHub Pages) and give that address.

**Graphics:** 512 x 512 icon from `docs/design/brand/icon-512.png`; 1024 x
500 feature graphic and phone screenshots (Home, a group, Add expense,
Sync) from a release build in light theme, plus one in dark theme.

## App content

| Question | Answer |
| --- | --- |
| Ads | No ads. |
| App access | All functionality is available without special access: no sign-in. |
| Target audience | 18 and over. Not designed for children. |
| Content rating (IARC questionnaire) | Category "Utility, productivity, communication or other". No violence, sexual content, profanity, drugs or gambling. Users can share content with each other: yes, but only with people they invite by QR code or link, directly between phones. No location sharing, no purchases. |
| News app | No. |
| Government app | No. |
| Financial features | None of the listed ones (no banking, loans, payments, crypto or trading). The app records amounts people owe each other; it moves no money. |
| Health | No. |

## Data safety

Play counts data as "collected" only when it leaves the device for the
developer or a third party. Settle Up sends nothing to the developer or to
any server. Data that goes from one user's phone to another's during sync
is user-initiated, transferred directly and end-to-end encrypted, so it is
not collected or shared in Play's sense. The ML Kit usage metrics that the
QR scanner library could send are disabled in the build (see below).

| Question | Answer |
| --- | --- |
| Does your app collect or share any of the required user data types? | **No.** |
| Is all of the user data collected by your app encrypted in transit? | Not asked when nothing is collected. (Sync between phones is AES-256-GCM.) |
| Do you provide a way for users to request that their data is deleted? | Not asked when nothing is collected. Users delete data in the app or with Clear storage (PRIVACY.md, "Deleting your data"). |
| Independent security review | No. |

Before each release, check that this is still true:

1. The merged release manifest (`build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`)
   has a `TransportBackendDiscovery` service with **no**
   `backend:com.google.android.datatransport.cct.CctBackendFactory`
   meta-data. `test/qa/security/android_manifest_test.dart` checks the
   rule in the source manifest.
2. No new dependency adds analytics, crash reporting or ads
   (`flutter pub deps`, and the merged manifest for new services and
   providers).
3. On a phone, docs/QA.md row P8: scanning a QR code with Wi-Fi on sends
   nothing to `firebaselogging-pa.googleapis.com` or any other host.

If any of these changes, update PRIVACY.md and declare the data here
("App info and performance: diagnostics, collected, not shared").

## Permission declarations

Play has declaration forms only for sensitive permissions such as
background location, SMS or all-files access. Settle Up requests none of
those, so no form is required. Play review may still ask why a permission
is used; these are the answers.

| Permission | Justification for review |
| --- | --- |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` (`maxSdkVersion 32`) | Foreground only, never background. Android 12L and older require location permission for Bluetooth LE scanning, Nearby Connections discovery and starting a local hotspot. The app finds a friend's phone nearby to sync expenses; it never reads, stores or sends the device location. The permission is not requested on Android 13 and later. |
| `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` ("Nearby devices") | Finding, connecting to and being found by a friend's phone to sync a shared expense group over Bluetooth or Nearby Connections, without internet. Requested on the Sync screen when Bluetooth sync needs it. Scans are never used to derive location. |
| `NEARBY_WIFI_DEVICES` (`neverForLocation`, Android 13+) | Nearby Connections over Wi-Fi between two phones during sync. |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` (`maxSdkVersion 30`) | The legacy Bluetooth permissions for the same sync on Android 11 and older. |
| `CAMERA` | Scanning a friend's invite or connect QR code. Frames are decoded on the device and never saved or uploaded. The camera is optional (`uses-feature required="false"`); a link can be pasted instead. |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | A direct TCP connection between two phones on the same Wi-Fi network or hotspot, and mDNS discovery on that network. The app contacts no internet server. |

## Release checklist for the listing

- [ ] Version in `pubspec.yaml` and docs/release-notes.md agree, and the
      versionCode is higher than any build already uploaded.
- [ ] Signed with the upload key from `android/key.properties` (README,
      "Release signing"), not the debug key.
- [ ] Privacy policy URL opens without a sign-in and shows this release's
      PRIVACY.md.
- [ ] Data safety answers re-checked with the three steps above.
- [ ] "What's new" text taken from docs/release-notes.md (500 characters
      max).
