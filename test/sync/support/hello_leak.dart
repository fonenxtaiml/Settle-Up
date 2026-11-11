// A HELLO frame check that fails only when a group id actually leaks.
//
// A HELLO carries three opaque, random fields (the ephemeral X25519 key,
// the nonce and the blinded group ids) as base64url. Their characters
// spell any short text now and then ("g1" in about 1 of 100 HELLOs), so a
// plain "frame text does not contain the id" check is flaky. This helper
// instead:
//
//  * decodes the frame (gunzipping a large body) and checks that every
//    opaque field decodes to bytes of its fixed length that are not an
//    encoding of the id (its UTF-8 bytes, its raw UUID bytes or its
//    base64url text);
//  * blanks exactly those opaque values and checks that nothing else in
//    the frame (header bytes, JSON keys, device id and name, app version,
//    transport, numbers) contains the id.
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';

/// HELLO fields that hold random bytes, with each value's decoded length.
const Map<String, int> kHelloOpaqueFields = {'eph': 32, 'nonce': 16};

/// Byte length of each entry in the HELLO `groups` list.
const int kHelloBlindedGroupBytes = 16;

/// Every place [frame] (a plain HELLO channel frame) shows [groupId] to an
/// observer. Empty when the id does not leak.
List<String> helloGroupIdLeaks(Uint8List frame, String groupId) {
  if (groupId.isEmpty) throw ArgumentError.value(groupId, 'groupId');
  // The frame must be a well-formed HELLO, so the opaque fields really are
  // fixed-length bytes and not free text.
  final hello = FrameCodec.decodePlainFrame(frame);
  if (hello is! HelloMessage) throw ArgumentError('not a HELLO frame');

  final header = frame.sublist(0, 3);
  var body = Uint8List.sublistView(frame, 3);
  if (header[2] & kFlagGzip != 0) {
    body = Uint8List.fromList(gzip.decode(body));
  }
  final bodyText = utf8.decode(body);
  final json = jsonDecode(bodyText) as Map<String, Object?>;

  final leaks = <String>[];
  final forms = _idByteForms(groupId);
  final opaque = <String>[];
  void checkOpaque(String field, Object? value, int length) {
    if (value is! String) {
      leaks.add('$field is not a string');
      return;
    }
    opaque.add(value);
    if (value == groupId) leaks.add('$field is the group id text');
    final bytes = _b64UrlDecode(value);
    if (bytes == null || bytes.length != length) {
      leaks.add('$field is not $length bytes of base64url');
      return;
    }
    for (final form in forms) {
      if (_same(bytes, form)) leaks.add('$field holds the group id bytes');
    }
  }

  kHelloOpaqueFields.forEach((f, n) => checkOpaque(f, json[f], n));
  final groups = json['groups'];
  if (groups is! List) {
    leaks.add('groups is not a list');
  } else {
    for (var i = 0; i < groups.length; i++) {
      checkOpaque('groups[$i]', groups[i], kHelloBlindedGroupBytes);
    }
  }

  // Everything that is not an opaque value, exactly as it is on the wire.
  var clear = bodyText;
  for (final v in opaque) {
    clear = clear.replaceAll('"$v"', '""');
  }
  if (String.fromCharCodes(header).contains(groupId)) {
    leaks.add('frame header');
  }
  if (clear.contains(groupId)) leaks.add('clear text: $clear');
  return leaks;
}

/// The byte strings that would carry [id] verbatim inside an opaque field.
List<Uint8List> _idByteForms(String id) {
  final forms = <Uint8List>[Uint8List.fromList(utf8.encode(id))];
  final hex = id.replaceAll('-', '');
  if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) {
    forms.add(
      Uint8List.fromList([
        for (var i = 0; i < 32; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]),
    );
  }
  final raw = _b64UrlDecode(id);
  if (raw != null && raw.isNotEmpty) forms.add(raw);
  return forms;
}

Uint8List? _b64UrlDecode(String s) {
  try {
    return base64Url.decode(base64Url.normalize(s));
  } on FormatException {
    return null;
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
