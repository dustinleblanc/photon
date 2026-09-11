import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:photon_library/ml/detection.dart';
import 'package:photon_library/ml/faces.dart';

void main() {
  test('COCO labels map to the right groups', () {
    expect(groupForLabel('person'), DetectionGroup.people);
    expect(groupForLabel('cat'), DetectionGroup.pets);
    expect(groupForLabel('dog'), DetectionGroup.pets);
    expect(groupForLabel('bird'), DetectionGroup.pets);
    expect(groupForLabel('horse'), DetectionGroup.pets);
    expect(groupForLabel('car'), DetectionGroup.objects);
    expect(groupForLabel('sink'), DetectionGroup.objects);

    expect(
      groupsForLabels(['person', 'cat', 'sink']),
      {DetectionGroup.people, DetectionGroup.pets, DetectionGroup.objects},
    );
  });

  test('DetectedEntry survives a serialization roundtrip', () {
    final entry = DetectedEntry(
      linkId: 'abc123',
      modelVersion: DetectorService.modelVersion,
      detectedAt: DateTime(2026, 9, 11),
      objects: [
        const DetectedObjectInfo(
          label: 'person',
          score: 0.93,
          rect: Rect.fromLTRB(0.1, 0.2, 0.5, 0.8),
        ),
        const DetectedObjectInfo(
          label: 'dog',
          score: 0.61,
          rect: Rect.fromLTRB(0.0, 0.0, 1.0, 1.0),
        ),
      ],
    );

    final restored = DetectedEntry.fromMap('abc123', entry.toMap());

    expect(restored.linkId, 'abc123');
    expect(restored.modelVersion, DetectorService.modelVersion);
    expect(restored.objects.length, 2);
    expect(restored.objects[0].label, 'person');
    expect(restored.objects[0].score, 0.93);
    expect(restored.objects[0].rect, const Rect.fromLTRB(0.1, 0.2, 0.5, 0.8));
    expect(
      restored.groups,
      {DetectionGroup.people, DetectionGroup.pets},
    );
  });

  test('cosineSimilarity is 1 for parallel vectors, -1 for opposites', () {
    final a = Float32List.fromList([1, 2, 3]);
    final b = Float32List.fromList([2, 4, 6]);
    final neg = Float32List.fromList([-1, -2, -3]);
    expect(cosineSimilarity(a, b), closeTo(1.0, 1e-9));
    expect(cosineSimilarity(a, neg), closeTo(-1.0, 1e-9));
    expect(cosineSimilarity(a, Float32List(3)), closeTo(0.0, 1e-9));
  });

  test('DetectedFace roundtrips name, similarity and embedding', () {
    final face = DetectedFace(
      rect: const Rect.fromLTRB(0.1, 0.2, 0.4, 0.6),
      embedding: Float32List.fromList([0.5, -0.25, 0.0, 1.0]),
      name: 'Mom',
      similarity: 0.82,
    );

    final restored = DetectedFace.fromMap(face.toMap());

    expect(restored.rect, face.rect);
    expect(restored.name, 'Mom');
    expect(restored.similarity, 0.82);
    expect(restored.embedding, face.embedding);
  });

  test('DetectedEntry roundtrips detected faces', () {
    final entry = DetectedEntry(
      linkId: 'faces-1',
      modelVersion: DetectorService.modelVersion,
      detectedAt: DateTime(2026, 9, 11),
      objects: const [],
      faces: [
        DetectedFace(
          rect: const Rect.fromLTRB(0.2, 0.1, 0.5, 0.55),
          embedding: Float32List.fromList([0.1, 0.2, 0.3]),
          name: 'Dad',
          similarity: 0.9,
        ),
        DetectedFace(
          rect: const Rect.fromLTRB(0.6, 0.3, 0.9, 0.7),
          embedding: Float32List.fromList([0.4, 0.5, 0.6]),
        ),
      ],
    );

    final restored = DetectedEntry.fromMap('faces-1', entry.toMap());

    expect(restored.faces.length, 2);
    expect(restored.faces[0].name, 'Dad');
    expect(restored.faces[1].name, isNull);
    expect(restored.people, {'Dad'});
  });

  test('PersonIdentity roundtrips its centroid and aliases', () {
    final id = PersonIdentity(
      name: 'Alice',
      aliases: ['Allie', 'Mom'],
      centroid: Float32List.fromList([0.2, -0.1, 0.9]),
      faceSamples: 5,
    );

    final restored = PersonIdentity.fromMap(id.toMap());

    expect(restored.name, 'Alice');
    expect(restored.aliases, ['Allie', 'Mom']);
    expect(restored.allNames, ['Alice', 'Allie', 'Mom']);
    expect(restored.faceSamples, 5);
    expect(restored.centroid, id.centroid);
  });

  test('mergePeople unions names and averages centroids by sample count', () {
    final a = PersonIdentity(
      name: 'Mom',
      aliases: ['Karen'],
      centroid: Float32List.fromList([1, 0, 0]),
      faceSamples: 2,
    );
    final b = PersonIdentity(
      name: 'Samantha',
      aliases: ['Sam'],
      centroid: Float32List.fromList([0, 1, 0]),
      faceSamples: 1,
    );

    final merged = mergePeople([a, b]);

    expect(merged.name, 'Mom');
    expect(merged.aliases, ['Karen', 'Sam', 'Samantha']);
    expect(merged.faceSamples, 3);
    expect(merged.centroid[0], closeTo(2 / 3, 1e-6));
    expect(merged.centroid[1], closeTo(1 / 3, 1e-6));
  });

  test('mergePeople honors an explicit primary name', () {
    final a = PersonIdentity(
      name: 'Mom',
      centroid: Float32List.fromList([1, 0]),
      faceSamples: 1,
    );
    final b = PersonIdentity(
      name: 'Karen',
      centroid: Float32List.fromList([0, 1]),
      faceSamples: 1,
    );

    final merged = mergePeople([a, b], primary: 'Karen');

    expect(merged.name, 'Karen');
    expect(merged.aliases, ['Mom']);
  });
}