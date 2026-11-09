First test build of Settle Up: offline expense splitting that syncs phone to phone over Wi-Fi hotspot or Bluetooth, with no internet and no account.

## Which file to install

- **settle-up-0.1.0-arm64.apk** (38 MB): almost every Android phone from the last 7 years. Start with this one.
- **settle-up-0.1.0-universal.apk** (107 MB): works on any Android phone. Use it if the arm64 file says "App not installed".

Android 8.0 or newer. Open the APK on the phone and allow "Install unknown apps" for your browser or file manager when asked. This build is signed with a debug key, so uninstall it before installing a later build if Android reports a signature conflict.

## What to try

1. Onboarding: your name; the home currency is preselected from your phone's region (₹ in India).
2. Create a group, add people, add expenses with each split method (equally, exact amounts, percent, shares, adjust) and with more than one payer.
3. Check balances, suggested payments with Simplify debts on and off, then Settle up.
4. Delete an expense and restore it; check Activity, Search, and CSV export from Settings.
5. Sync with a second phone:
   - **Hotspot:** phone A turns on its hotspot, opens Sync and taps "Make this phone visible". Phone B joins the hotspot and either picks phone A from Nearby phones or scans its QR code.
   - **Bluetooth:** both phones open Sync; they should appear under Nearby phones. Allow the Nearby devices / Bluetooth permission when asked.
   - To add a friend to a group, open the group's Members screen, show the invite QR code, and let them scan it.
   After a sync, both phones should show identical balances.

## Known limits in 0.1.0

- Real-radio sync (hotspot, Nearby, Bluetooth) has only been tested in code against simulated phones; this is the first build on real devices.
- Pairing a Bluetooth phone without scanning a QR code, live auto-sync, receipt photos, recurring expenses, currency conversion and cloud sync come in later versions.
- If both phones tap Sync on each other at the same moment, one may report "busy"; tap Sync again.
