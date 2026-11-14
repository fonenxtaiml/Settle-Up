// Names another phone gives us: the device name in its HELLO, in its
// advert (mDNS service name, Nearby endpoint name, BLE INFO) and in a
// connect or invite link. They are shown in the nearby list, on the
// session screen and in Sync history, so they get the same cleaning as
// names typed on this phone (SPEC 5.16, `TextClean` in core): no control, bidi or zero-width
// characters, line breaks as spaces, trimmed.
//
// They are the peer's word, and a link may come from any web page (SPEC
// 8.9): its `n` and `f` values are bounded only by the size of the link.
// So a name is cut to [kMaxPeerNameUnits] code units before it is
// normalised, and reading it takes the same short time whatever was sent
// (SECURITY-R15-02).
import '../core/name_text.dart';

/// The most UTF-16 code units of a peer's name that are read. A name this
/// phone sends is saved first, so it holds at most [NameText.maxGroupLength]
/// x [NameText.unitsPerChar] (240) code units; four times that leaves room
/// for a name another app version sent unnormalised.
const int kMaxPeerNameUnits =
    4 * NameText.maxGroupLength * NameText.unitsPerChar;

/// [raw] cleaned for matching: its first [kMaxPeerNameUnits] code units
/// in the form names typed on this phone take ([NameText.normalize]), not
/// cut to a name limit (an mDNS " (2)" suffix may still follow the name).
String cleanPeerName(String raw) => NameText.normalize(boundPeerName(raw));

/// [raw] as it may be shown or stored: its first [kMaxPeerNameUnits] code
/// units saved as a name of at most [limit] characters is on this phone
/// ([NameText.fit]). A received name is the peer's word, and a link from
/// any web page may carry hundreds of characters; shown and recorded, it
/// takes no more room than a name typed on a phone (SECURITY-R39-01). A
/// phone name is at most [NameText.maxLength] characters (SPEC 5.16).
String fitPeerName(String raw, [int limit = NameText.maxLength]) =>
    NameText.fit(boundPeerName(raw), limit);

/// The first [kMaxPeerNameUnits] code units of [raw], never half of a
/// surrogate pair.
String boundPeerName(String raw) {
  if (raw.length <= kMaxPeerNameUnits) return raw;
  var end = kMaxPeerNameUnits;
  final last = raw.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return raw.substring(0, end);
}
