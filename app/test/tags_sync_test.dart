import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photon_library/ml/detection.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

void main() {
  late Directory tmp;
  late DetectionIndex index;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('photon_tags_test');
    index = DetectionIndex();
    await index.init(
      dirOverride: tmp,
      keyOverride: List<int>.filled(32, 7),
    );
  });

  tearDown(() async {
    await index.clear();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Hive's lock-file cleanup can race the recursive delete; the temp
      // dir is throwaway either way.
    }
  });

  Float32List emb(double seed) => Float32List.fromList(
        List<double>.generate(192, (i) => (i + seed) / 1000),
      );

  DetectedEntry entryWithFace(String linkId, Float32List embedding,
      {String? name}) {
    return DetectedEntry(
      linkId: linkId,
      modelVersion: DetectorService.modelVersion,
      detectedAt: DateTime(2026, 9, 11),
      objects: const [],
      faces: [
        DetectedFace(
          rect: const Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
          embedding: embedding,
          name: name,
        ),
      ],
    );
  }

  test('unseen remote identities are inserted as new people', () async {
    await index.applyRemoteIdentities([
      PersonIdentity(
        name: 'Logan',
        centroid: emb(1),
        faceSamples: 4,
      ),
    ]);

    final id = index.identityForName('logan');
    expect(id, isNotNull);
    expect(id!.faceSamples, 4);
  });

  test('matching identities merge centroids weighted by samples', () async {
    await index.upsertIdentity('Mom', emb(10));
    final merged = await index.applyRemoteIdentities([
      PersonIdentity(
        name: 'Mom',
        aliases: ['Mother'],
        centroid: emb(20),
        faceSamples: 3,
      ),
    ]);

    expect(merged.length, 1);
    final id = index.identityForName('Mom')!;
    expect(id.faceSamples, 4);
    expect(id.aliases, contains('Mother'));
    // 1 local sample + 3 remote samples: (0.010 + 3*0.020)/4 = 0.0175
    expect(id.centroid[0], closeTo(0.0175, 1e-6));
  });

  test('the side with more samples supplies the canonical name', () async {
    // Local "Mom" has 1 sample; remote "Karen" has 5 and lists Mom as alias.
    await index.upsertIdentity('Mom', emb(1));
    await index.applyRemoteIdentities([
      PersonIdentity(
        name: 'Karen',
        aliases: ['Mom'],
        centroid: emb(2),
        faceSamples: 5,
      ),
    ]);

    expect(index.identityForName('Karen'), isNotNull);
    expect(index.identityForName('Mom')!.name, 'Karen');
    // The face stored under the old canonical name was renamed.
    expect(index.identityForName('Karen')!.allNames, contains('Mom'));
  });

  test('remote identities backfill names onto unnamed stored faces',
      () async {
    final local = emb(1);
    await index.put(entryWithFace('photo1', local));
    // No local identities yet: the face is unnamed.
    expect(index.facesFor('photo1').single.name, isNull);

    await index.applyRemoteIdentities([
      PersonIdentity(name: 'Dad', centroid: local, faceSamples: 2),
    ]);

    expect(index.facesFor('photo1').single.name, 'Dad');
    expect(index.facesFor('photo1').single.similarity, closeTo(1.0, 1e-6));
  });

  test('ignored faces are never backfilled', () async {
    final local = emb(1);
    final e = entryWithFace('photo2', local);
    e.faces[0].ignored = true;
    await index.put(e);

    await index.applyRemoteIdentities([
      PersonIdentity(name: 'Dad', centroid: local, faceSamples: 2),
    ]);

    expect(index.facesFor('photo2').single.name, isNull);
    expect(index.facesFor('photo2').single.ignored, isTrue);
  });

  test('empty or malformed remote identities are skipped', () async {
    await index.upsertIdentity('Mom', emb(1));
    final merged = await index.applyRemoteIdentities([
      PersonIdentity(name: '', centroid: emb(2), faceSamples: 1),
      PersonIdentity(
        name: 'NoCentroid',
        centroid: Float32List(0),
        faceSamples: 0,
      ),
    ]);
    expect(merged.length, 1);
    expect(merged.single.name, 'Mom');
  });

  test('clearing low-confidence tags keeps manual tags and embeddings',
      () async {
    // A manual tag (similarity 1.0) and a loose auto-tag (0.55, under the
    // current 0.6 threshold) on separate photos.
    final manual = entryWithFace('photo-manual', emb(1), name: 'Mom');
    manual.faces[0].similarity = 1.0;
    await index.put(manual);
    final loose = entryWithFace('photo-loose', emb(2), name: 'Mom');
    loose.faces[0].similarity = 0.55;
    await index.put(loose);

    await index.clearLowConfidenceAssignments();

    expect(index.facesFor('photo-manual').single.name, 'Mom');
    expect(index.facesFor('photo-loose').single.name, isNull);
    // The embedding is kept so the face can be re-matched.
    expect(index.facesFor('photo-loose').single.embedding.length, 192);
  });
}