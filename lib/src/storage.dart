import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the SDK keeps its ids, flags and the offline event queue.
abstract class VectorSignalStorage {
  Future<String?> read(String key);

  /// Writes a value; `null` removes it.
  Future<void> write(String key, String? value);

  Future<List<Map<String, dynamic>>> loadQueue();

  Future<void> saveQueue(List<Map<String, dynamic>> queue);
}

/// Default storage: small values in SharedPreferences, the queue as a JSON
/// file in the app's private support directory (not visible to other apps).
class DefaultVectorSignalStorage implements VectorSignalStorage {
  static const _prefix = 'vector_signal.';
  static const _queueFileName = 'vector_signal_queue.json';

  SharedPreferences? _prefs;
  File? _queueFile;

  Future<SharedPreferences> _getPrefs() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<File> _getQueueFile() async {
    if (_queueFile != null) return _queueFile!;
    final dir = await getApplicationSupportDirectory();
    return _queueFile =
        File('${dir.path}${Platform.pathSeparator}$_queueFileName');
  }

  @override
  Future<String?> read(String key) async =>
      (await _getPrefs()).getString(_prefix + key);

  @override
  Future<void> write(String key, String? value) async {
    final prefs = await _getPrefs();
    if (value == null) {
      await prefs.remove(_prefix + key);
    } else {
      await prefs.setString(_prefix + key, value);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> loadQueue() async {
    try {
      final file = await _getQueueFile();
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      // A corrupt file must never break the host app; start with an empty queue.
      return [];
    }
  }

  @override
  Future<void> saveQueue(List<Map<String, dynamic>> queue) async {
    final file = await _getQueueFile();
    // Write to a temp file then rename, so a crash mid-write can't corrupt the queue.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(queue), flush: true);
    await tmp.rename(file.path);
  }
}

/// In-memory storage, for tests or when nothing should touch the disk.
class MemoryVectorSignalStorage implements VectorSignalStorage {
  final Map<String, String> values = {};
  List<Map<String, dynamic>> queue = [];
  int saveCount = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<List<Map<String, dynamic>>> loadQueue() async =>
      queue.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> saveQueue(List<Map<String, dynamic>> queue) async {
    saveCount++;
    this.queue = queue.map((e) => Map<String, dynamic>.from(e)).toList();
  }
}
