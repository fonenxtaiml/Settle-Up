# Release notes

## 1.0.0

Version `1.0.0+2`: versionName `1.0.0`, versionCode `2` (`version:` in
`pubspec.yaml`). The 0.1.0 tester builds used versionCode `1`, so every
1.0.0 build has a higher code, and Settings > About shows `1.0.0 (2)`.
Bump the number after the `+` for every APK handed to testers or uploaded
to Play; Play rejects a versionCode it has already seen.

- **Install note for 0.1.0 testers.** 0.1.0 was signed with the Android
  debug key and used the codename app id `app.settleup.settle_up`. 1.0.0 is
  signed with the Settle Up release key and uses the final app id
  `app.settleup.settleup`, so it cannot install over 0.1.0 and shows up as
  a second "Settle Up" on the phone. Data does not move between them:
  backup and device-to-device transfer are off by design (SPEC 7.4). Before
  removing 0.1.0, make sure every expense you entered there has been synced
  to at least one friend's phone; then join your groups again in 1.0.0 with
  an invite and sync to get the history back. Uninstall 0.1.0 afterwards so
  `settleup://` links open the right app.
- New launcher icon and launch screen in the Point to Point style (the
  tether, ink on stone), including Android 13 themed icons.
- The invite QR, which carries the group key, is kept out of screenshots,
  screen recordings and the recents thumbnail while it is shown.
- App data is excluded from cloud backup and from device-to-device transfer
  to a new phone (Android 12+), so a copied op log can never clone this
  phone's device id.
