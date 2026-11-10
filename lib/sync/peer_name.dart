// Names another phone gives us: the device name in its HELLO, in its
// advert (mDNS service name, Nearby endpoint name, BLE INFO) and in a
// connect or invite link. They are shown in the nearby list, on the
// session screen and in Sync history, so they get the same cleaning as
// names typed on this phone (SPEC 5.16, `TextClean` in core): no control, bidi or zero-width
// characters, line breaks as spaces, trimmed.
import '../core/text_clean.dart';

/// [raw] as it may be shown or stored.
String cleanPeerName(String raw) => TextClean.clean(raw);
