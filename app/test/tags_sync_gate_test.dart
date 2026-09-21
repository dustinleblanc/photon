import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photon_library/api/serve_client.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/sync/tags_sync.dart';

/// Counts network calls so the [TagsSync.canSync] gate can be asserted.
class _CountingClient extends ServeClient {
  _CountingClient() : super(url: 'http://127.0.0.1:1');

  int gets = 0;
  int puts = 0;

  @override
  Future<Map<String, dynamic>> getTags() async {
    gets++;
    return {'revision': 0, 'identities': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> putTags({
    required int baseRevision,
    required List<Map<String, dynamic>> identities,
  }) async {
    puts++;
    return {'revision': baseRevision + 1};
  }
}

void main() {
  test('canSync false makes no network calls', () async {
    final client = _CountingClient();
    final sync = TagsSync(
      client: client,
      index: DetectionIndex(),
      canSync: () => false,
    );

    await sync.pullAndPush();

    expect(client.gets, 0);
    expect(client.puts, 0);
  });

  test('canSync true pulls and pushes', () async {
    final tmp = await Directory.systemTemp.createTemp('photon_gate_');
    final index = DetectionIndex();
    await index.init(dirOverride: tmp, keyOverride: List<int>.filled(32, 1));
    addTearDown(() async {
      await index.clear();
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Hive lock cleanup can race the delete; the dir is throwaway.
      }
    });

    final client = _CountingClient();
    final sync = TagsSync(client: client, index: index, canSync: () => true);

    await sync.pullAndPush();

    expect(client.gets, 1);
    expect(client.puts, 1);
  });
}
