import 'dart:math';

/// Random version-4 UUID from a secure random source.
String newUuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Hands out the current session id. A new session starts after [timeout]
/// with no events (this also covers the app coming back from a long time in
/// the background, because nothing is recorded while it is paused).
class SessionTracker {
  final Duration timeout;
  String? _id;
  DateTime? _lastActivity;

  SessionTracker({this.timeout = const Duration(minutes: 30)});

  String? get currentId => _id;

  /// Returns the session id for an event at [now], starting a new one if needed.
  String touch(DateTime now) {
    final last = _lastActivity;
    if (_id == null || last == null || now.difference(last) > timeout) {
      _id = newUuidV4();
    }
    _lastActivity = now;
    return _id!;
  }

  /// Forces a new session on the next event (e.g. after [VectorSignal.reset]).
  void end() {
    _id = null;
    _lastActivity = null;
  }
}
