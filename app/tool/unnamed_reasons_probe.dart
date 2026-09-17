import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

/// For every unnamed face in the worklist, reports which gate rejected it and
/// what identity/scores it came closest to.
///   flutter run -d macos -t tool/unnamed_reasons_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();
  final matcher = index.faceMatcher();
  final ids = index.identities;

  var belowPeak = 0, belowCentroid = 0, ambiguous = 0, matched = 0;
  final examples = <String>[];

  for (final u in index.unnamedFaces()) {
    final entry = index.lookup(u.linkId);
    if (entry == null) continue;
    final f = entry.faces[u.faceIndex];
    PersonIdentity? best;
    var bestPeak = 0.0, bestCentroid = 0.0, rival = 0.0;
    for (final id in ids) {
      final peak = matcher.scoreFor(f.embedding, id);
      final centroid =
          faceMatchScore(f.embedding, matcher.effectiveCentroid(id));
      if (best == null || peak > bestPeak) {
        best = id;
        bestPeak = peak;
        bestCentroid = centroid;
      }
    }
    if (best == null) continue;
    for (final id in ids) {
      if (id.name == best.name) continue;
      final c = faceMatchScore(f.embedding, matcher.effectiveCentroid(id));
      if (c > rival) rival = c;
    }
    final reason = matcher.match(f.embedding) != null
        ? 'MATCHED?'
        : bestPeak < kDefaultFaceMatchThreshold
            ? 'peak'
            : bestCentroid < kDefaultFaceMatchThreshold - kCentroidFloorDelta
                ? 'centroid'
                : 'ambiguous';
    switch (reason) {
      case 'peak':
        belowPeak++;
      case 'centroid':
        belowCentroid++;
      case 'ambiguous':
        ambiguous++;
      default:
        matched++;
    }
    if (examples.length < 25) {
      examples.add('  ${reason.padRight(9)} best=${best.name.padRight(18)} '
          'peak=${bestPeak.toStringAsFixed(3)} '
          'centroid=${bestCentroid.toStringAsFixed(3)} '
          'rival=${rival.toStringAsFixed(3)} '
          'samples=${best.faceSamples} link=${u.linkId}');
    }
  }
  stderr.writeln('reasons: belowPeak=$belowPeak belowCentroid=$belowCentroid '
      'ambiguous=$ambiguous matched=$matched');

  final clusters = index.unnamedClusters();
  var largest = 0;
  var multi = 0;
  for (final c in clusters) {
    if (c.length > largest) largest = c.length;
    if (c.length > 1) multi++;
  }
  var suggestible = 0;
  for (final c in clusters) {
    final entry = index.lookup(c.first.linkId);
    if (entry == null) continue;
    final emb = entry.faces[c.first.faceIndex].embedding;
    if (emb.isNotEmpty && matcher.suggestion(emb) != null) suggestible++;
  }
  final totalFaces = clusters.fold<int>(0, (a, c) => a + c.length);
  stderr.writeln('worklist: faces=$totalFaces tiles=${clusters.length} '
      'multiFaceTiles=$multi largestCluster=$largest '
      'tilesWithSuggestion=$suggestible');
  for (final e in examples) {
    stderr.writeln(e);
  }
  exit(0);
}
