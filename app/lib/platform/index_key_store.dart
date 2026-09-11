import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Stores the 32-byte AES key used to encrypt the on-device detection index.
///
/// On Android the key lives in the platform Keychain (flutter_secure_storage).
/// macOS debug builds aren't code-signed with the keychain entitlements and
/// fail with errSecMissingEntitlement (-34018), so on non-Android platforms we
/// fall back to a 0600 file inside the app support directory instead.
class IndexKeyStore {
  static const _storage = FlutterSecureStorage();
  static const _androidKeyName = 'photon_ml_index_key';
  static const _fileName = 'photon_ml_index.key';

  static Future<Uint8List> getOrCreate() async {
    if (Platform.isAndroid) return _android();
    return _fileFallback();
  }

  static Future<Uint8List> _android() async {
    final existing = await _storage.read(key: _androidKeyName);
    if (existing != null) return base64Decode(existing);
    final key = _random();
    await _storage.write(key: _androidKeyName, value: base64Encode(key));
    return key;
  }

  static Future<Uint8List> _fileFallback() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_fileName');
    if (await file.exists()) {
      try {
        final bytes = base64Decode(await file.readAsString());
        if (bytes.length == 32) return bytes;
      } catch (_) {}
    }
    final key = _random();
    await file.writeAsString(base64Encode(key), flush: true);
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
    return key;
  }

  static Uint8List _random() {
    final rng = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
  }
}