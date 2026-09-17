import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'package:photon_library/api/serve_client.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';
import 'package:photon_library/ml/illustration.dart';

/// Compares face-crop statistics between known illustrations (whole-image
/// flagged) and real photos, to derive a face-level "drawn face" filter.
///   SAMPLE=25 flutter run -d macos -t tool/face_style_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sample = int.tryParse(Platform.environment['SAMPLE'] ?? '25') ?? 25;
  final index = DetectionIndex();
  await index.init();

  final all = index.debugEntries().values.toList();
  final illus = all.where((e) => e.illustration).toList()
    ..shuffle(math.Random(1));
  final photos = all
      .where((e) => !e.illustration && e.faces.isNotEmpty)
      .toList()
    ..shuffle(math.Random(2));

  final client = ServeClient();
  final svc = FaceRecognitionService();

  Future<List<IllustrationResult>> cropsOf(String linkId) async {
    final bytes = await client.preview(linkId, size: 1600);
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return const [];
    final faces = await svc.detectFaces(
      bytes: bytes,
      imageWidth: decoded.width,
      imageHeight: decoded.height,
    );
    final out = <IllustrationResult>[];
    for (final f in faces) {
      final crop = cropFaceJpegFromDecoded(decoded, f.rect, size: 200);
      final cropped = img.decodeImage(crop);
      if (cropped == null) continue;
      out.add(analyseIllustration(cropped));
    }
    return out;
  }

  final illusStats = <IllustrationResult>[];
  var done = 0;
  for (final e in illus) {
    if (done >= sample) break;
    try {
      final r = await cropsOf(e.linkId);
      if (r.isEmpty) continue;
      illusStats.addAll(r);
      done++;
    } catch (_) {}
  }
  final photoStats = <IllustrationResult>[];
  done = 0;
  for (final e in photos) {
    if (done >= sample) break;
    try {
      final r = await cropsOf(e.linkId);
      if (r.isEmpty) continue;
      photoStats.addAll(r);
      done++;
    } catch (_) {}
  }
  await svc.dispose();

  void report(String label, List<IllustrationResult> s) {
    if (s.isEmpty) {
      stderr.writeln('$label: no faces');
      return;
    }
    double avg(double Function(IllustrationResult) f) =>
        s.fold<double>(0, (a, r) => a + f(r)) / s.length;
    stderr.writeln('$label: faces=${s.length} '
        'colors=${avg((r) => r.uniqueColors.toDouble()).toStringAsFixed(0)} '
        'flat=${avg((r) => r.flatRatio).toStringAsFixed(3)} '
        'conc=${avg((r) => r.paletteConcentration).toStringAsFixed(3)} '
        'sat=${avg((r) => r.saturatedShare).toStringAsFixed(3)}');
  }
  report('ILLUS', illusStats);
  report('PHOTO', photoStats);

  double pct(List<IllustrationResult> s, double p, double Function(IllustrationResult) f) {
    final v = [for (final r in s) f(r)]..sort();
    if (v.isEmpty) return 0;
    return v[(p * (v.length - 1)).round()];
  }
  void pcts(String label, List<IllustrationResult> s) {
    stderr.writeln('$label: flat p10=${pct(s, 0.1, (r) => r.flatRatio).toStringAsFixed(2)} '
        'p50=${pct(s, 0.5, (r) => r.flatRatio).toStringAsFixed(2)} '
        'p90=${pct(s, 0.9, (r) => r.flatRatio).toStringAsFixed(2)} | '
        'conc p10=${pct(s, 0.1, (r) => r.paletteConcentration).toStringAsFixed(2)} '
        'p50=${pct(s, 0.5, (r) => r.paletteConcentration).toStringAsFixed(2)} '
        'p90=${pct(s, 0.9, (r) => r.paletteConcentration).toStringAsFixed(2)}');
  }
  pcts('ILLUS', illusStats);
  pcts('PHOTO', photoStats);

  for (final t in const [
    [0.20, 0.65],
    [0.25, 0.65],
    [0.25, 0.70],
    [0.30, 0.70],
  ]) {
    final fp = photoStats.where((r) => r.flatRatio >= t[0] && r.paletteConcentration >= t[1]).length;
    final tp = illusStats.where((r) => r.flatRatio >= t[0] && r.paletteConcentration >= t[1]).length;
    stderr.writeln('  flat>=${t[0]} conc>=${t[1]}: '
        'drawn caught $tp/${illusStats.length} '
        'real dropped $fp/${photoStats.length}');
  }
  exit(0);
}
