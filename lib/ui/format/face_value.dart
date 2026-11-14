import '../../core/money.dart';

/// [minor] units of [from] as minor units of [to] with the same face value:
/// ₹300 (30000) is ¥300 (300) or KD 300 (300000), never ¥30,000 or KD 30.
///
/// Null when [to] cannot hold that value exactly (₹300.50 has no yen
/// equivalent: yen have no decimals) or the result passes
/// [Money.maxMinor]. Used wherever a form moves amounts it already holds
/// to another currency (QA UIFLOW-R39-02), so minor units are never read
/// in a currency they were not typed in.
int? sameFaceValue(int minor, Currency from, Currency to) {
  if (minor < 0) {
    final v = sameFaceValue(-minor, from, to);
    return v == null ? null : -v;
  }
  final d = to.minorDigits - from.minorDigits;
  if (d == 0) return minor > Money.maxMinor ? null : minor;
  var f = 1;
  for (var i = 0; i < d.abs(); i++) {
    f *= 10;
  }
  if (d < 0) {
    return minor % f == 0 ? minor ~/ f : null;
  }
  // minor * f > maxMinor, checked without overflowing.
  if (minor > Money.maxMinor ~/ f) return null;
  final v = minor * f;
  return v > Money.maxMinor ? null : v;
}
