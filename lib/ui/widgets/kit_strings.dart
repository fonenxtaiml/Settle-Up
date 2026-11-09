// Copy used inside the design-system widgets (DESIGN.md section 7).
//
// Screens keep their copy in lib/ui/strings.dart (owned by ui-screens).
// The widget kit cannot depend on that file, so the few phrases the
// widgets render themselves live here, written to the same rules: sentence
// case, fixed direction words, "this phone" rather than "device".
import '../format/money_format.dart';

abstract final class KitStrings {
  // Direction words (DESIGN 7.2). Fixed everywhere.
  static const owesYou = 'owes you';
  static const youOwe = 'you owe';
  static const youreOwed = "you're owed";
  static const even = 'even';
  static const youLent = 'you lent';
  static const youBorrowed = 'you borrowed';
  static const notInvolved = 'not involved';
  static const getsBack = 'gets back';
  static const owes = 'owes';

  // Level vial end words.
  static const vialOwe = 'owe';
  static const vialOwed = 'owed';

  // Balance hero.
  static const heroOwedLead = 'Overall, you are owed';
  static const heroOweLead = 'Overall, you owe';
  static const heroSettled = "You're all even";
  static String heroOweTotal(String amount) => 'You owe $amount in total.';
  static String heroOwedTotal(String amount) =>
      'You are owed $amount in total.';
  static String heroPlusOwed(String amount) => 'Plus $amount owed to you';
  static String heroPlusOwe(String amount) => 'Plus $amount you owe';

  static String moreCurrencies(int n) => '+$n more';

  // Expense rows.
  static String paid(String payer, String amount) => '$payer paid $amount';
  static String peoplePaid(int n, String amount) => '$n people paid $amount';
  static String paymentTitle(String from, String to) => '$from paid $to';
  static const payment = 'Payment';
  static const notYetShared = 'Not yet shared';
  static const restore = 'Restore';
  static const deleted = 'deleted';
  static const someone = 'Someone';

  // Avatar.
  static const notOnSettleUp = 'not on Settle Up yet';

  // Split selector and remainder.
  static const splitEqually = 'Equally';
  static const splitAmounts = 'Amounts';
  static const splitPercent = 'Percent';
  static const splitShares = 'Shares';
  static const splitAdjust = 'Adjust';
  static String leftToAssign(String amount) => '$amount left to assign';
  static String allAssigned(String amount) => 'All $amount assigned';
  static String tooMuch(String amount) =>
      "$amount too much. Lower someone's share.";

  // Sync chip (DESIGN 5.8). Never "offline".
  static const onThisPhone = 'On this phone';
  static String syncedAgo(String ago) => 'Synced $ago';
  static const synced = 'Synced';
  static String changesToShare(int n) =>
      n == 1 ? '1 change to share' : '$n changes to share';
  static String syncingWith(String name) => 'Syncing with $name';
  static const syncing = 'Syncing';
  static const syncStopped = 'Sync stopped';

  // Keypad.
  static const amount = 'Amount';
  static const deleteDigit = 'Delete';
  static const changeCurrency = 'Change currency';

  // Nearby sheet (DESIGN 5.9).
  static const phonesNearby = 'Phones nearby';
  static const searching = 'Searching by Wi-Fi and Bluetooth';
  static const unknownPhone = 'Unknown phone';
  static const sync = 'Sync';
  static const pair = 'Pair';
  static const wifi = 'Wi-Fi';
  static const bluetooth = 'Bluetooth';
  static String shares(String groups) => 'shares $groups';
  static const noSharedGroups = 'no shared groups';
  static const cantSeeThem = "Can't see them?";
  static const cantSeeThemBody =
      'Make sure they opened Sync and tapped "Make this phone visible".';
  static const showMyQr = 'Show my QR code';
  static const scanQr = 'Scan a QR code';
  static String checkCode(String name, String code) =>
      "Check that $name's phone shows $code";

  /// Screen-reader amount without plus/minus words (DESIGN 3.4).
  static String spokenAmount(int minor, String currency) =>
      MoneyFormat.spoken(minor, currency);
}
