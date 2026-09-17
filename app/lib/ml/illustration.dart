import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'faces.dart';

/// Cheap on-device "is this a photo or an illustration" heuristic.
///
/// Illustrations, cartoons, screenshots and memes share two traits that
/// natural photographs rarely have:
///   1. a small palette — few distinct colours once quantised, because
///      regions are flat-filled rather than textured;
///   2. large exactly-flat runs — adjacent pixels byte-identical, because
///      there is no sensor noise.
///
/// Photographs (even smooth ones like skies) carry noise and gradients, so
/// exact-equality runs stay short and the palette is large. The thresholds
/// are deliberately conservative: only very flat, very low-palette images
/// are flagged, since a false positive means a real photo's faces are
/// excluded from automatic tagging.
class IllustrationResult {
  const IllustrationResult({
    required this.uniqueColors,
    required this.flatRatio,
    required this.isIllustration,
    this.paletteConcentration = 0,
    this.saturatedShare = 0,
  });

  final int uniqueColors;
  final double flatRatio;

  /// Fraction of pixels covered by the 64 most common quantised colours.
  /// Illustrations/screenshots concentrate (flat fills); photographs spread
  /// across many shades.
  final double paletteConcentration;

  /// Fraction of pixels closer to a primary/secondary hue than to grey.
  final double saturatedShare;

  final bool isIllustration;

  Map<String, dynamic> toMap() => {
        'uniqueColors': uniqueColors,
        'flatRatio': flatRatio,
        'paletteConcentration': paletteConcentration,
        'saturatedShare': saturatedShare,
      };
}

/// Recall-leaning thresholds: a mostly-flat image with a small palette.
/// Calibrated against the real library — photographs topped out around 0.31
/// flatness (even smooth skies), so 0.50 catches drawings and screenshots
/// while leaving photos alone. False positives remain possible, which is why
/// the manual mark/clear override exists.
const int kMaxIllustrationColors = 2500;
const double kMinIllustrationFlatness = 0.50;

/// Tolerance-based flatness: neighbours within [kFlatTolerance] per channel.
/// JPEG/resize artifacts break exact equality, so a small tolerance is far
/// more robust for detecting the flat interiors of drawings.
const int kFlatTolerance = 1;

/// Analyses a decoded preview. Sampling is strided so cost is bounded
/// regardless of preview size.
IllustrationResult analyseIllustration(img.Image image) {
  final w = image.width;
  final h = image.height;
  if (w < 4 || h < 4) {
    return const IllustrationResult(
      uniqueColors: 1 << 20,
      flatRatio: 0,
      isIllustration: false,
    );
  }
  final stepX = (w ~/ 200).clamp(1, w);
  final stepY = (h ~/ 200).clamp(1, h);

  final histogram = <int, int>{};
  var sampled = 0;
  var flat = 0;
  var saturated = 0;
  for (var y = 1; y < h - 1; y += stepY) {
    for (var x = 1; x < w - 1; x += stepX) {
      final p = image.getPixel(x, y);
      final pr = p.r.toInt();
      final pg = p.g.toInt();
      final pb = p.b.toInt();
      final key = ((pr >> 3) << 10) | ((pg >> 3) << 5) | (pb >> 3);
      histogram[key] = (histogram[key] ?? 0) + 1;

      final right = image.getPixel(x + 1, y);
      final below = image.getPixel(x, y + 1);
      final near = (pr - right.r.toInt()).abs() <= kFlatTolerance &&
          (pg - right.g.toInt()).abs() <= kFlatTolerance &&
          (pb - right.b.toInt()).abs() <= kFlatTolerance &&
          (pr - below.r.toInt()).abs() <= kFlatTolerance &&
          (pg - below.g.toInt()).abs() <= kFlatTolerance &&
          (pb - below.b.toInt()).abs() <= kFlatTolerance;
      if (near) flat++;

      final maxC = [pr, pg, pb].reduce((a, b) => a > b ? a : b);
      final minC = [pr, pg, pb].reduce((a, b) => a < b ? a : b);
      if (maxC - minC > 60) saturated++;
      sampled++;
    }
  }
  if (sampled == 0) {
    return const IllustrationResult(
      uniqueColors: 1 << 20,
      flatRatio: 0,
      isIllustration: false,
    );
  }
  final sorted = histogram.values.toList()..sort((a, b) => b.compareTo(a));
  final top = sorted.take(64).fold<int>(0, (a, b) => a + b);
  final concentration = top / sampled;
  final flatRatio = flat / sampled;
  final saturatedShare = saturated / sampled;
  return IllustrationResult(
    uniqueColors: histogram.length,
    flatRatio: flatRatio,
    paletteConcentration: concentration,
    saturatedShare: saturatedShare,
    isIllustration: histogram.length < kMaxIllustrationColors &&
        flatRatio > kMinIllustrationFlatness,
  );
}

/// A face crop that is this flat with this concentrated a palette is a
/// drawing, not a photograph. Calibrated on real data: separates cartoon
/// faces (flat p50 0.25, concentration 0.78) from real ones (0.09 / 0.49),
/// catching roughly half of drawn faces while misclassifying only very soft
/// real faces — whose embeddings are weak anyway.
const double kDrawnFaceFlatness = 0.28;
const double kDrawnFaceConcentration = 0.66;

/// True when the decoded face [crop] looks drawn rather than photographed.
bool looksDrawnFace(img.Image crop) {
  final r = analyseIllustration(crop);
  return r.flatRatio >= kDrawnFaceFlatness &&
      r.paletteConcentration >= kDrawnFaceConcentration;
}

/// Isolate-friendly check for several faces at once: [args] carries the
/// encoded image and each face's normalized rect as (x, y, x2, y2) quads.
/// Returns one flag per rect (true = drawn), or null when undecodable.
List<bool>? drawnFacesFromBytes((Uint8List, List<double>) args) {
  final (bytes, coords) = args;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final out = <bool>[];
  for (var i = 0; i + 3 < coords.length; i += 4) {
    final rect = Rect.fromLTRB(
      coords[i],
      coords[i + 1],
      coords[i + 2],
      coords[i + 3],
    );
    final crop = cropFaceJpegFromDecoded(decoded, rect, size: 200);
    final cropped = img.decodeImage(crop);
    out.add(cropped != null && looksDrawnFace(cropped));
  }
  return out;
}

/// Decodes and classifies in a background isolate, so scanning a whole
/// library doesn't block the UI thread (decoding a 1600px JPEG is tens of
/// milliseconds each, which adds up badly across thousands of photos).
/// Returns null when the bytes can't be decoded.
bool? classifyIllustrationBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return analyseIllustration(decoded).isIllustration;
}

/// Decode + dimension + style, all off the UI thread, for the scan path.
/// Returns null when the bytes can't be decoded.
(int, int, bool)? analysePreviewBytes(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final style = analyseIllustration(decoded);
  return (decoded.width, decoded.height, style.isIllustration);
}
