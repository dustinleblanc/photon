import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'index_key_store.dart';

/// Persistent, encrypted on-disk cache of rendered photo previews.
///
/// Entries are the decrypted JPEGs returned by the sidecar, sealed with the
/// same AES-256 key as the detection index ([IndexKeyStore]) so nothing is
/// readable on disk without the key. They live under the OS cache directory,
/// which the system may reclaim at any time; a missing or corrupt entry just
/// re-fetches from the server.
///
/// Sizes are capped (least-recently-used entries are dropped first) because a
/// full library of HD previews can be many gigabytes.
class PreviewCache {
  PreviewCache({Directory? dirOverride, List<int>? keyOverride})
      : this._(dirOverride, keyOverride);

  PreviewCache._(this._dirOverride, this._keyOverride);

  /// Soft cap on the total size of the cache.
  static const int maxBytes = 512 * 1024 * 1024;

  final Directory? _dirOverride;
  final List<int>? _keyOverride;

  HiveAesCipher? _cipher;
  Directory? _dir;
  int _bytes = 0;

  bool get available => _dir != null && _cipher != null;

  /// Resolves the key and cache directory. Idempotent, and never throws:
  /// on failure the cache simply stays disabled and previews go to the wire.
  Future<void> init() async {
    if (available) return;
    try {
      final key = _keyOverride ?? await IndexKeyStore.getOrCreate();
      final base = _dirOverride ?? await getApplicationCacheDirectory();
      final dir = Directory('${base.path}/previews')
        ..createSync(recursive: true);
      final cipher = HiveAesCipher(key);
      _cipher = cipher;
      _dir = dir;
      _bytes = _dirSize(dir);
      if (_bytes > maxBytes) _trim();
    } catch (_) {
      _cipher = null;
      _dir = null;
    }
  }

  /// Returns the decrypted bytes for `linkId@size`, or null on a miss. A
  /// corrupt entry is deleted and treated as a miss.
  Future<Uint8List?> get(String linkId, int size) async {
    final cipher = _cipher;
    final file = _file(linkId, size);
    if (cipher == null || file == null || !file.existsSync()) return null;
    try {
      final sealed = await file.readAsBytes();
      final out = Uint8List(sealed.length);
      final len = cipher.decrypt(sealed, 0, sealed.length, out, 0);
      // Refresh the mtime so eviction drops least-recently-used entries.
      try {
        file.setLastModifiedSync(DateTime.now());
      } catch (_) {}
      return Uint8List.sublistView(out, 0, len);
    } catch (_) {
      try {
        file.deleteSync();
      } catch (_) {}
      return null;
    }
  }

  /// Encrypts and stores [bytes], replacing any existing entry atomically.
  Future<void> put(String linkId, int size, Uint8List bytes) async {
    final cipher = _cipher;
    final file = _file(linkId, size);
    if (cipher == null || file == null) return;
    final tmp = File('${file.path}.tmp');
    try {
      final out = Uint8List(cipher.maxEncryptedSize(bytes));
      final len = cipher.encrypt(bytes, 0, bytes.length, out, 0);
      await tmp.writeAsBytes(Uint8List.sublistView(out, 0, len), flush: true);
      await tmp.rename(file.path);
      _bytes += len;
      if (_bytes > maxBytes) _trim();
    } catch (_) {
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
  }

  File? _file(String linkId, int size) {
    final dir = _dir;
    if (dir == null) return null;
    return File('${dir.path}/${_name(linkId, size)}');
  }

  /// A filesystem-safe, opaque filename. Link ids are already opaque, but
  /// base64url keeps us safe if one ever contains a path separator.
  static String _name(String linkId, int size) =>
      base64Url.encode(utf8.encode('$linkId@$size')).replaceAll('=', '');

  void _trim() {
    final dir = _dir;
    if (dir == null) return;
    try {
      final entries = <({File file, DateTime modified, int size})>[];
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        if (e.path.endsWith('.tmp')) {
          try {
            e.deleteSync();
          } catch (_) {}
          continue;
        }
        try {
          final stat = e.statSync();
          entries.add((file: e, modified: stat.modified, size: stat.size));
        } catch (_) {}
      }
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      var total = entries.fold<int>(0, (sum, e) => sum + e.size);
      final target = (maxBytes * 0.8).round();
      for (final e in entries) {
        if (total <= target) break;
        try {
          e.file.deleteSync();
          total -= e.size;
        } catch (_) {}
      }
      _bytes = total;
    } catch (_) {}
  }

  static int _dirSize(Directory dir) {
    var total = 0;
    try {
      for (final e in dir.listSync()) {
        if (e is File) {
          try {
            total += e.statSync().size;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}
