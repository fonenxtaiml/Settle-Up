// Cutting a device name to fit a limit (HELLO, mDNS, Nearby, BLE): the
// other phone shows what it gets in its nearby list, on the session screen
// and in Sync history, so a cut keeps whole characters (grapheme
// clusters): never half a flag, a conjunct without its last letter, or a
// letter outside the BMP split into a lone surrogate (DATA-R4-03,
// DATA-R5-01).
import 'package:characters/characters.dart';

/// The longest prefix of [name] made of whole characters for which [fits]
/// holds. [fits] must hold for every prefix of a string it holds for (a
/// limit on units, code points or bytes).
///
/// When not even the first character fits (one letter carrying more
/// combining marks than the limit), that character is cut by code points
/// instead: the base letter and the marks that fit, so the name is never
/// empty while its first code point fits (DATA-R5-02). Code points are
/// never split, so the result is always well-formed UTF-16.
String cutName(String name, bool Function(String candidate) fits) {
  if (fits(name)) return name;
  var out = '';
  for (final ch in name.characters) {
    final next = '$out$ch';
    if (!fits(next)) break;
    out = next;
  }
  if (out.isNotEmpty || name.isEmpty) return out;
  final first = name.characters.first;
  for (final r in first.runes) {
    final next = '$out${String.fromCharCode(r)}';
    if (!fits(next)) break;
    out = next;
  }
  return out;
}
