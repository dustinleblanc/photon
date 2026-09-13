import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:photon_library/ml/detection.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

Float32List _unit(int dim, int index) =>
    Float32List.fromList(List.generate(dim, (j) => j == index ? 1.0 : 0.0));

void main() {
  test('reconcileIdentities heals a corrupted centroid from manual faces',
      () async {
    final dir = Directory.systemTemp.createTempSync('photon_index_');
    final key = List<int>.generate(32, (i) => i);
    final index = DetectionIndex();
    await index.init(dirOverride: dir, keyOverride: key);
    addTearDown(() async {
      await index.dispose();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    // Three manually named faces for Dustin (similarity 1.0).
    for (var i = 0; i < 3; i++) {
      await index.put(
        DetectedEntry(
          linkId: 'photo-$i',
          modelVersion: DetectorService.modelVersion,
          detectedAt: DateTime(2026, 9, 13),
          objects: const [],
          faces: [
            DetectedFace(
              rect: Rect.fromLTRB(0.1 * i, 0, 0.1 * i + 0.1, 0.1),
              embedding: _unit(4, i),
              name: 'Dustin',
              similarity: 1.0,
            ),
          ],
        ),
      );
    }

    // A healthy synced identity that must be left untouched.
    final box = Hive.box<Map>('identities_v1');
    await box.put(
      'Ali',
      PersonIdentity(
        name: 'Ali',
        centroid: Float32List.fromList([0.6, 0.8, 0.0, 0.0]),
        faceSamples: 5,
      ).toMap(),
    );
    // The corrupted identity: exploded centroid + garbage sample count.
    await box.put(
      'Dustin',
      PersonIdentity(
        name: 'Dustin',
        centroid: Float32List.fromList(List.filled(4, 1e35)),
        faceSamples: -792299531789139840,
      ).toMap(),
    );

    await index.reconcileIdentities();

    final dustin = index.identities.firstWhere((i) => i.name == 'Dustin');
    expect(dustin.faceSamples, 3);
    expect(dustin.centroid.length, 4);
    expect(dustin.centroid.every((v) => v.isFinite && v.abs() <= 1), isTrue);
    // Mean of the three unit vectors.
    for (var i = 0; i < 3; i++) {
      expect(dustin.centroid[i], closeTo(1 / 3, 1e-6));
    }
    expect(dustin.centroid[3], closeTo(0.0, 1e-6));

    final ali = index.identities.firstWhere((i) => i.name == 'Ali');
    expect(ali.faceSamples, 5);
    expect(ali.centroid[0], closeTo(0.6, 1e-6));
    expect(ali.centroid[1], closeTo(0.8, 1e-6));
  });
}
