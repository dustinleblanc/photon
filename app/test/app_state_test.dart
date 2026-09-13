import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:photon_library/api/models.dart';
import 'package:photon_library/api/serve_client.dart';
import 'package:photon_library/platform/preview_cache.dart';
import 'package:photon_library/state/app_state.dart';

Photo _photo(String id) => Photo(linkId: id, captureTime: 0);

List<int> _key() => List<int>.generate(32, (i) => i);

class _PagedServeClient extends ServeClient {
  _PagedServeClient(this.pages) : super(url: 'http://127.0.0.1:1');

  final Map<String?, AssetsPage> pages;
  int calls = 0;
  Uint8List previewResult = Uint8List(0);
  int previewCalls = 0;

  @override
  Future<AssetsPage> listAssets({String? cursor, int pageSize = 200}) async {
    calls++;
    return pages[cursor] ?? const AssetsPage(assets: []);
  }

  @override
  Future<Uint8List> preview(String linkId, {int size = 512}) async {
    previewCalls++;
    return previewResult;
  }
}

void main() {
  test('libraryLinkIds pages through the whole library', () async {
    final client = _PagedServeClient({
      null: AssetsPage(
        assets: [_photo('a'), _photo('b')],
        nextCursor: 'b',
      ),
      'b': AssetsPage(
        assets: [_photo('c'), _photo('d')],
        nextCursor: 'd',
      ),
      'd': AssetsPage(assets: [_photo('e')]),
    });
    final state = AppState(client: client);
    addTearDown(state.dispose);

    expect(await state.libraryLinkIds(), ['a', 'b', 'c', 'd', 'e']);
    expect(client.calls, 3);
  });

  test('libraryLinkIds stops if the cursor does not advance', () async {
    final client = _PagedServeClient({
      null: AssetsPage(assets: [_photo('a')], nextCursor: 'a'),
      'a': AssetsPage(assets: [_photo('b')], nextCursor: 'a'),
    });
    final state = AppState(client: client);
    addTearDown(state.dispose);

    // Must terminate rather than loop forever on a stuck cursor.
    expect(await state.libraryLinkIds(), ['a', 'b']);
  });

  test('previews are served from the encrypted disk cache across instances',
      () async {
    final dir = Directory.systemTemp.createTempSync('photon_state_cache_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    final clientA = _PagedServeClient({})..previewResult = bytes;
    final cacheA = PreviewCache(dirOverride: dir, keyOverride: _key());
    await cacheA.init();
    final stateA = AppState(client: clientA, previewCache: cacheA);
    addTearDown(stateA.dispose);

    expect(await stateA.preview('photo-1'), bytes);
    expect(clientA.previewCalls, 1);

    // A fresh app instance with a fresh (network) client should hit the disk.
    final clientB = _PagedServeClient({})
      ..previewResult = Uint8List.fromList([9, 9, 9]);
    final cacheB = PreviewCache(dirOverride: dir, keyOverride: _key());
    await cacheB.init();
    final stateB = AppState(client: clientB, previewCache: cacheB);
    addTearDown(stateB.dispose);

    expect(await stateB.preview('photo-1'), bytes);
    expect(clientB.previewCalls, 0);
  });
}
