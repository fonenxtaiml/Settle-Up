// Protocol v1 messages (SPEC 8.5). Every message is a JSON object body
// carried in a plain or sealed frame (codec.dart). Decoding validates every
// field and throws [ProtocolException] so hostile input never reaches the
// store as anything but a rejected frame.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/ops.dart';
import '../../core/version_vector.dart';

/// Highest protocol version this build speaks.
const int kProtocolVersion = 1;

/// Lowest protocol version this build accepts.
const int kMinProtocolVersion = 1;

/// `app` field of HELLO.
const String kAppVersion = 'settleup/1.0.0';

/// Wire type codes (SPEC 8.5). 11/12 (blobs) and 20-29 (pairing) are
/// reserved: a receiver of an unknown type answers `ERROR bad_frame`.
enum MessageType {
  hello(1),
  auth(2),
  vv(3),
  ops(4),
  ack(5),
  done(6),
  ping(7),
  pong(8),
  error(9),
  bye(10);

  const MessageType(this.code);
  final int code;

  static MessageType? fromCode(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// `ERROR.code` values (SPEC 8.5).
abstract final class ErrorCodes {
  static const protoUnsupported = 'proto_unsupported';
  static const noSharedGroups = 'no_shared_groups';
  static const authFailed = 'auth_failed';
  static const badFrame = 'bad_frame';
  static const badOp = 'bad_op';
  static const tooLarge = 'too_large';
  static const busy = 'busy';
  static const cancelled = 'cancelled';
  static const internal = 'internal';
}

/// A frame or message that violates the protocol. [code] is one of
/// [ErrorCodes] and is what the receiver reports to the peer.
final class ProtocolException implements Exception {
  const ProtocolException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'ProtocolException($code: $message)';
}

// ------------------------------------------------------------- limits --

/// Longest device id / group id accepted on the wire.
const int kMaxIdLength = 64;

/// Longest device name accepted in HELLO.
const int kMaxDeviceNameLength = 100;

/// Most blinded group ids accepted in one HELLO.
const int kMaxHelloGroups = 256;

/// Most ops accepted in one OPS batch (SPEC 8.5 batching).
const int kMaxOpsPerBatch = 500;

// -------------------------------------------------------------- base64 --

/// base64url without padding (the encoding used for every binary field).
String b64UrlEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Accepts base64url with or without padding. Throws FormatException.
Uint8List b64UrlDecode(String s) {
  if (s.length % 4 == 1) throw const FormatException('Bad base64 length');
  return base64Url.decode(s.padRight(s.length + (4 - s.length % 4) % 4, '='));
}

// ------------------------------------------------------------- messages --

sealed class SyncMessage {
  const SyncMessage();

  MessageType get type;

  Map<String, Object?> toJson();

  /// Builds the message of [type] from its JSON body. Throws
  /// [ProtocolException] (`bad_frame`, or `bad_op` for a malformed op).
  static SyncMessage fromJson(MessageType type, Map<String, Object?> json) {
    final r = _Reader(json);
    return switch (type) {
      MessageType.hello => HelloMessage._read(r),
      MessageType.auth => AuthMessage(mac: r.bytes('mac', 32)),
      MessageType.vv => VvMessage(groupId: r.id('g'), vv: r.vv('vv')),
      MessageType.ops => OpsMessage._read(r),
      MessageType.ack => AckMessage(
          groupId: r.id('g'),
          batch: r.positiveInt('batch'),
          vv: r.vv('vv'),
        ),
      MessageType.done => DoneMessage(groupId: r.id('g')),
      MessageType.ping => PingMessage(r.int_('t')),
      MessageType.pong => PongMessage(r.int_('t')),
      MessageType.error => ErrorMessage(
          r.string('code', maxLength: 64),
          r.optionalString('msg', maxLength: 1000) ?? '',
        ),
      MessageType.bye => const ByeMessage(),
    };
  }
}

@immutable
final class HelloMessage extends SyncMessage {
  const HelloMessage({
    required this.deviceId,
    required this.deviceName,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.blindedGroups,
    required this.maxFrame,
    required this.transport,
    this.proto = kProtocolVersion,
    this.minProto = kMinProtocolVersion,
    this.app = kAppVersion,
  });

  factory HelloMessage._read(_Reader r) {
    final groups = r.list('groups', maxLength: kMaxHelloGroups);
    final blinded = <Uint8List>[];
    for (final g in groups) {
      if (g is! String) throw const ProtocolException(ErrorCodes.badFrame);
      blinded.add(_decodeFixed(g, 16, 'groups'));
    }
    final transportName = r.string('transport', maxLength: 16);
    final transport = TransportKind.values
        .where((k) => k.name == transportName)
        .firstOrNull;
    if (transport == null) {
      throw ProtocolException(ErrorCodes.badFrame, 'transport $transportName');
    }
    return HelloMessage(
      proto: r.positiveInt('proto'),
      minProto: r.positiveInt('minProto'),
      deviceId: r.id('deviceId'),
      deviceName: r.string('deviceName', maxLength: kMaxDeviceNameLength),
      app: r.string('app', maxLength: 64),
      ephemeralPublicKey: r.bytes('eph', 32),
      nonce: r.bytes('nonce', 16),
      blindedGroups: blinded,
      maxFrame: r.positiveInt('maxFrame'),
      transport: transport,
    );
  }

  final int proto;
  final int minProto;
  final DeviceId deviceId;
  final String deviceName;
  final String app;
  final Uint8List ephemeralPublicKey; // 32 bytes, X25519
  final Uint8List nonce; // 16 bytes, fresh per connection
  final List<Uint8List> blindedGroups; // 16 bytes each (SPEC 8.3)
  final int maxFrame;
  final TransportKind transport;

  @override
  MessageType get type => MessageType.hello;

  @override
  Map<String, Object?> toJson() => {
        'proto': proto,
        'minProto': minProto,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'app': app,
        'eph': b64UrlEncode(ephemeralPublicKey),
        'nonce': b64UrlEncode(nonce),
        'groups': [for (final g in blindedGroups) b64UrlEncode(g)],
        'maxFrame': maxFrame,
        'transport': transport.name,
      };
}

@immutable
final class AuthMessage extends SyncMessage {
  const AuthMessage({required this.mac});
  final Uint8List mac; // 32 bytes

  @override
  MessageType get type => MessageType.auth;

  @override
  Map<String, Object?> toJson() => {'mac': b64UrlEncode(mac)};
}

@immutable
final class VvMessage extends SyncMessage {
  const VvMessage({required this.groupId, required this.vv});
  final GroupId groupId;
  final VersionVector vv;

  @override
  MessageType get type => MessageType.vv;

  @override
  Map<String, Object?> toJson() => {'g': groupId, 'vv': vv.toJson()};
}

@immutable
final class OpsMessage extends SyncMessage {
  const OpsMessage({
    required this.groupId,
    required this.batch,
    required this.total,
    required this.ops,
    required this.more,
  });

  factory OpsMessage._read(_Reader r) {
    final raw = r.list('ops', maxLength: kMaxOpsPerBatch);
    final ops = <Operation>[];
    for (final o in raw) {
      if (o is! Map) throw const ProtocolException(ErrorCodes.badOp);
      try {
        ops.add(Operation.fromJson(Map<String, Object?>.from(o)));
      } on FormatException catch (e) {
        throw ProtocolException(ErrorCodes.badOp, e.message);
      }
    }
    return OpsMessage(
      groupId: r.id('g'),
      batch: r.positiveInt('batch'),
      total: r.nonNegativeInt('total'),
      ops: ops,
      more: r.boolean('more'),
    );
  }

  final GroupId groupId;
  final int batch; // 1-based per group and session
  final int total; // ops the sender will send for this group (progress)
  final List<Operation> ops; // sorted by (deviceId, counter)
  final bool more;

  @override
  MessageType get type => MessageType.ops;

  @override
  Map<String, Object?> toJson() => {
        'g': groupId,
        'batch': batch,
        'total': total,
        'ops': [for (final op in ops) op.toJson()],
        'more': more,
      };
}

@immutable
final class AckMessage extends SyncMessage {
  const AckMessage({
    required this.groupId,
    required this.batch,
    required this.vv,
  });
  final GroupId groupId;
  final int batch;
  final VersionVector vv; // receiver's contiguous VV after the commit

  @override
  MessageType get type => MessageType.ack;

  @override
  Map<String, Object?> toJson() =>
      {'g': groupId, 'batch': batch, 'vv': vv.toJson()};
}

@immutable
final class DoneMessage extends SyncMessage {
  const DoneMessage({required this.groupId});
  final GroupId groupId;

  @override
  MessageType get type => MessageType.done;

  @override
  Map<String, Object?> toJson() => {'g': groupId};
}

@immutable
final class PingMessage extends SyncMessage {
  const PingMessage(this.t);
  final int t; // sender's ms clock

  @override
  MessageType get type => MessageType.ping;

  @override
  Map<String, Object?> toJson() => {'t': t};
}

@immutable
final class PongMessage extends SyncMessage {
  const PongMessage(this.t);
  final int t; // echoed from PING

  @override
  MessageType get type => MessageType.pong;

  @override
  Map<String, Object?> toJson() => {'t': t};
}

@immutable
final class ErrorMessage extends SyncMessage {
  const ErrorMessage(this.code, [this.msg = '']);
  final String code; // ErrorCodes
  final String msg;

  @override
  MessageType get type => MessageType.error;

  @override
  Map<String, Object?> toJson() => {'code': code, 'msg': msg};
}

@immutable
final class ByeMessage extends SyncMessage {
  const ByeMessage();

  @override
  MessageType get type => MessageType.bye;

  @override
  Map<String, Object?> toJson() => const {};
}

// ------------------------------------------------------------- reading --

Uint8List _decodeFixed(String value, int length, String field) {
  try {
    final bytes = b64UrlDecode(value);
    if (bytes.length == length) return bytes;
  } on FormatException {
    // fall through
  }
  throw ProtocolException(ErrorCodes.badFrame, 'field $field');
}

/// Typed, validating access to a JSON body.
final class _Reader {
  _Reader(this.json);
  final Map<String, Object?> json;

  Never _bad(String field) =>
      throw ProtocolException(ErrorCodes.badFrame, 'field $field');

  String string(String field, {required int maxLength}) {
    final v = json[field];
    if (v is! String || v.length > maxLength) _bad(field);
    return v;
  }

  String? optionalString(String field, {required int maxLength}) {
    final v = json[field];
    if (v == null) return null;
    if (v is! String || v.length > maxLength) _bad(field);
    return v;
  }

  String id(String field) {
    final v = string(field, maxLength: kMaxIdLength);
    if (v.isEmpty) _bad(field);
    return v;
  }

  int int_(String field) {
    final v = json[field];
    if (v is! int) _bad(field);
    return v;
  }

  int positiveInt(String field) {
    final v = int_(field);
    if (v < 1) _bad(field);
    return v;
  }

  int nonNegativeInt(String field) {
    final v = int_(field);
    if (v < 0) _bad(field);
    return v;
  }

  bool boolean(String field) {
    final v = json[field];
    if (v is! bool) _bad(field);
    return v;
  }

  List<Object?> list(String field, {required int maxLength}) {
    final v = json[field];
    if (v is! List || v.length > maxLength) _bad(field);
    return v;
  }

  Uint8List bytes(String field, int length) =>
      _decodeFixed(string(field, maxLength: 4 * length), length, field);

  VersionVector vv(String field) {
    final v = json[field];
    if (v is! Map || v.length > 10000) _bad(field);
    final out = <DeviceId, int>{};
    for (final e in v.entries) {
      final k = e.key, n = e.value;
      if (k is! String || k.isEmpty || k.length > kMaxIdLength) _bad(field);
      if (n is! int || n < 0) _bad(field);
      out[k] = n;
    }
    return VersionVector(out);
  }
}
