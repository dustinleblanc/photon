import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photon_library/ml/detection.dart';
import 'package:photon_library/ml/illustration.dart';

void main() {
  test('flat limited-palette art is flagged as an illustration', () {
    final image = img.Image(width: 200, height: 200);
    // Big flat fills: sky, ground, a couple of shapes.
    img.fillRect(image, x1: 0, y1: 0, x2: 199, y2: 120,
        color: img.ColorRgb8(90, 160, 220));
    img.fillRect(image, x1: 0, y1: 121, x2: 199, y2: 199,
        color: img.ColorRgb8(60, 170, 80));
    img.fillCircle(image, x: 50, y: 50, radius: 30,
        color: img.ColorRgb8(250, 240, 120));
    img.fillRect(image, x1: 120, y1: 60, x2: 180, y2: 100,
        color: img.ColorRgb8(200, 60, 60));

    final result = analyseIllustration(image);

    expect(result.isIllustration, isTrue,
        reason: 'colors=${result.uniqueColors} flat=${result.flatRatio}');
  });

  test('a noisy photograph is not flagged', () {
    final rng = Random(42);
    final image = img.Image(width: 200, height: 200);
    for (var y = 0; y < 200; y++) {
      for (var x = 0; x < 200; x++) {
        image.setPixelRgb(
          x,
          y,
          rng.nextInt(256),
          rng.nextInt(256),
          rng.nextInt(256),
        );
      }
    }

    final result = analyseIllustration(image);

    expect(result.isIllustration, isFalse,
        reason: 'colors=${result.uniqueColors} flat=${result.flatRatio}');
  });

  test('illustration flag adds the Illustrations group', () {
    final entry = DetectedEntry(
      linkId: 'x',
      modelVersion: DetectorService.modelVersion,
      detectedAt: DateTime(2026, 9, 13),
      objects: const [],
      illustration: true,
    );
    expect(entry.groups, contains(DetectionGroup.illustrations));
    // Round-trips through the index encoding.
    final restored = DetectedEntry.fromMap('x', entry.toMap());
    expect(restored.illustration, isTrue);
    expect(restored.groups, contains(DetectionGroup.illustrations));
  });

  test('copyWith preserves illustration/style flags', () {
    final entry = DetectedEntry(
      linkId: 'x',
      modelVersion: DetectorService.modelVersion,
      detectedAt: DateTime(2026, 9, 13),
      objects: const [],
      illustration: true,
      styleChecked: true,
    );
    final copy = entry.copyWith(faces: const []);
    expect(copy.illustration, isTrue);
    expect(copy.styleChecked, isTrue);
  });
}
