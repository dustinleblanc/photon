import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:photon_library/platform/preview_cache.dart';

List<int> _key() => List<int>.generate(32, (i) => i);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('photon_preview_cache_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  PreviewCache cacheFor(List<int> key) =>
      PreviewCache(dirOverride: dir, keyOverride: key);

  test('round-trips bytes through the encrypted cache', () async {
    final cache = cacheFor(_key());
    await cache.init();
    final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 256));

    await cache.put('photo', 512, bytes);

    expect(await cache.get('photo', 512), bytes);
  });

  test('returns null for a miss', () async {
    final cache = cacheFor(_key());
    await cache.init();

    expect(await cache.get('missing', 512), isNull);
  });

  test('writes ciphertext, not the raw image bytes', () async {
    final cache = cacheFor(_key());
    await cache.init();
    final bytes = Uint8List.fromList(List.filled(64, 7));

    await cache.put('photo', 1600, bytes);

    final files = Directory('${dir.path}/previews')
        .listSync()
        .whereType<File>()
        .toList();
    expect(files, hasLength(1));
    expect(files.single.readAsBytesSync(), isNot(equals(bytes)));
  });

  test('discards a corrupt entry and treats it as a miss', () async {
    final cache = cacheFor(_key());
    await cache.init();
    await cache.put('photo', 512, Uint8List.fromList([1, 2, 3]));

    final file = Directory('${dir.path}/previews')
        .listSync()
        .whereType<File>()
        .single;
    file.writeAsBytesSync(Uint8List.fromList([0, 0, 0, 0]));

    expect(await cache.get('photo', 512), isNull);
    expect(file.existsSync(), isFalse);
  });

  test('a different key cannot read entries', () async {
    final writer = cacheFor(_key());
    await writer.init();
    await writer.put('photo', 512, Uint8List.fromList([4, 5, 6]));

    final reader = cacheFor(List<int>.generate(32, (i) => 255 - i));
    await reader.init();

    expect(await reader.get('photo', 512), isNull);
  });
}
