import 'dart:convert';

import 'package:dio/dio.dart';

import 'storage.dart';

/// Session replay settings of the project, set on the Vector Signal
/// dashboard (Project settings, Session replay).
class ReplaySettings {
  /// Replay is on for this project (and the server can store it).
  final bool enabled;

  /// Share of sessions recorded in full, 0..1.
  final double sampleRate;

  /// Share of the other sessions whose last minute is kept on the device and
  /// sent only when a struggle happens, 0..1.
  final double onStruggleSampleRate;

  const ReplaySettings({
    required this.enabled,
    required this.sampleRate,
    required this.onStruggleSampleRate,
  });

  /// Replay off: the default until the app has loaded the project's settings.
  static const off =
      ReplaySettings(enabled: false, sampleRate: 0, onStruggleSampleRate: 0);

  /// True when some sessions will be recorded.
  bool get records => enabled && (sampleRate > 0 || onStruggleSampleRate > 0);

  factory ReplaySettings.fromJson(Map<String, dynamic> json) => ReplaySettings(
        enabled: json['enabled'] == true,
        sampleRate: _rate(json['sampleRate']),
        onStruggleSampleRate: _rate(json['onStruggleSampleRate']),
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'sampleRate': sampleRate,
        'onStruggleSampleRate': onStruggleSampleRate,
      };

  static double _rate(Object? value) =>
      value is num ? value.toDouble().clamp(0.0, 1.0) : 0.0;
}

/// Settings the app reads from its project at start-up, so they can be
/// changed on the dashboard without releasing a new app.
class ProjectSettings {
  final ReplaySettings replay;

  const ProjectSettings({required this.replay});

  factory ProjectSettings.fromJson(Map<String, dynamic> json) {
    final replay = json['replay'];
    return ProjectSettings(
      replay: replay is Map
          ? ReplaySettings.fromJson(Map<String, dynamic>.from(replay))
          : ReplaySettings.off,
    );
  }

  Map<String, dynamic> toJson() => {'replay': replay.toJson()};

  static const _storageKey = 'project_settings';

  /// The settings saved by the last successful fetch, or null.
  static Future<ProjectSettings?> load(VectorSignalStorage storage) async {
    try {
      final raw = await storage.read(_storageKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? ProjectSettings.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(VectorSignalStorage storage) async {
    try {
      await storage.write(_storageKey, jsonEncode(toJson()));
    } catch (_) {}
  }
}

/// Where the project's settings come from. The default [HttpSettingsSource]
/// asks Vector Signal; tests supply their own.
abstract class VectorSignalSettingsSource {
  /// The current settings, or null when they could not be loaded (offline,
  /// server error); the SDK then keeps the last saved ones.
  Future<ProjectSettings?> fetch();
}

/// Reads `{host}/v1/settings` with the project's write key.
class HttpSettingsSource implements VectorSignalSettingsSource {
  final String writeKey;
  final Dio _dio;

  HttpSettingsSource({required this.writeKey, required String host, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: host,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ));

  @override
  Future<ProjectSettings?> fetch() async {
    try {
      final response = await _dio.get<dynamic>(
        '/v1/settings',
        options: Options(
          headers: {'X-VS-Write-Key': writeKey},
          validateStatus: (_) => true,
        ),
      );
      final body = response.data;
      if (response.statusCode != 200 || body is! Map) return null;
      final data = body['data'];
      return data is Map
          ? ProjectSettings.fromJson(Map<String, dynamic>.from(data))
          : null;
    } catch (_) {
      return null;
    }
  }
}
