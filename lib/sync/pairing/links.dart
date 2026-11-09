// FROZEN CONTRACT (docs/SPEC.md section 8.6). Owner: sync-core.
// QR / deep-link payloads. Pure Dart, fully specified here.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/ids.dart';

String _b64(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64(String s) =>
    base64Url.decode(s.padRight(s.length + (4 - s.length % 4) % 4, '='));

/// `settleup://join?v=1&g={groupId}&k={b64url key}&n={name}&c={currency}`
/// `&f={inviter device name}[&h={host:port}][&d={inviter deviceId}]`
@immutable
final class InviteLink {
  const InviteLink({
    required this.groupId,
    required this.groupKey,
    required this.groupName,
    required this.currency,
    required this.fromName,
    this.host,
    this.deviceId,
  });

  final GroupId groupId;
  final Uint8List groupKey; // 32 bytes
  final String groupName;
  final String currency;
  final String fromName;
  final String? host; // 'ip:port'
  final DeviceId? deviceId;

  String encode() => Uri(
        scheme: 'settleup',
        host: 'join',
        queryParameters: {
          'v': '1',
          'g': groupId,
          'k': _b64(groupKey),
          'n': groupName,
          'c': currency,
          'f': fromName,
          'h': ?host,
          'd': ?deviceId,
        },
      ).toString();

  /// Returns null if [link] is not a valid v1 invite.
  static InviteLink? tryParse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'settleup' || uri.host != 'join') {
      return null;
    }
    final q = uri.queryParameters;
    if (q['v'] != '1') return null;
    final g = q['g'], k = q['k'], n = q['n'], c = q['c'];
    if (g == null || k == null || n == null || c == null) return null;
    try {
      final key = _unb64(k);
      if (key.length != 32) return null;
      return InviteLink(
        groupId: g,
        groupKey: key,
        groupName: n,
        currency: c,
        fromName: q['f'] ?? '',
        host: q['h'],
        deviceId: q['d'],
      );
    } on FormatException {
      return null;
    }
  }
}

/// `settleup://sync?v=1&h={host:port}[&h={host:port}...]&d={deviceId}`
/// `&n={device name}`
@immutable
final class ConnectLink {
  const ConnectLink({
    required this.hosts,
    required this.deviceId,
    required this.deviceName,
  });

  final List<String> hosts; // tried in order
  final DeviceId deviceId;
  final String deviceName;

  String encode() {
    final parts = <String>[
      'v=1',
      for (final h in hosts) 'h=${Uri.encodeQueryComponent(h)}',
      'd=${Uri.encodeQueryComponent(deviceId)}',
      'n=${Uri.encodeQueryComponent(deviceName)}',
    ];
    return 'settleup://sync?${parts.join('&')}';
  }

  static ConnectLink? tryParse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || uri.scheme != 'settleup' || uri.host != 'sync') {
      return null;
    }
    final q = uri.queryParametersAll;
    if (q['v']?.first != '1') return null;
    final hosts = q['h'] ?? const [];
    final d = q['d']?.first;
    if (hosts.isEmpty || d == null) return null;
    return ConnectLink(
      hosts: hosts,
      deviceId: d,
      deviceName: q['n']?.first ?? '',
    );
  }
}
