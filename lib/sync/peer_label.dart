// What this phone shows for another phone: the nearby list, the session
// screen, Sync history, the "Synced with ..." lines and the join prompt.
//
// A peer's name (its HELLO, its advert, a link) is the peer's word, and a
// peer on any app version, or a forged one, may send a name that shows
// nothing: '', a zero-width space, a Hangul filler (U+3164, U+115F,
// U+1160, U+FFA0), the braille blank, a lone combining mark, punctuation.
// Every place that shows a peer name reads it through [shownPeerName],
// which turns such a name into '' (so the caller's usual "empty: use the
// next source" fallbacks apply), and ends with [kUnnamedPeer] when no
// source has a name (DATA-R6-01).
import '../core/text_clean.dart';
import 'peer_name.dart';

/// Shown for a phone that sent no name worth showing.
const String kUnnamedPeer = 'Phone';

/// [raw] cleaned and cut to the phone-name limit ([fitPeerName]) when it
/// shows something to tell a phone by, else ''. Every received phone name
/// (HELLO, advert, link `n` and `f`) is shown and recorded in this form, so
/// none takes more than a phone name's room (SECURITY-R39-01).
String shownPeerName(String raw) {
  final name = fitPeerName(raw);
  return showsPeerName(name) ? name : '';
}

/// The first of [candidates] that [shownPeerName] keeps, else
/// [kUnnamedPeer]. Never blank.
String peerLabel(Iterable<String> candidates) {
  for (final raw in candidates) {
    final name = shownPeerName(raw);
    if (name.isNotEmpty) return name;
  }
  return kUnnamedPeer;
}

/// Whether [name] holds at least one letter or number (Unicode L* or N*)
/// that draws as one: the Hangul fillers are letters (Lo) by category but
/// draw as blank space, so they do not count. Spaces, format and control
/// characters, marks, symbols and punctuation alone are no name.
bool showsPeerName(String name) {
  for (final r in name.runes) {
    if (TextClean.isHidden(r) || TextClean.isBlankMark(r)) continue;
    if (_letterOrNumber.hasMatch(String.fromCharCode(r))) return true;
  }
  return false;
}

final RegExp _letterOrNumber = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
