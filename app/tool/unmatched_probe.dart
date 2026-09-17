import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

/// Classifies every unnamed face in the real index: would the matcher assign
/// it, and if not, was it below threshold or rejected as ambiguous (margin)?
/// Run: flutter run -d macos -t tool/unmatched_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();
  stderr.writeln('probe: available=${index.available}');

  final ids = index.identities;
  final matcher = index.faceMatcher();
  stderr.writeln('probe: identities=${ids.length}');

  final entries = index.debugEntries();
  var totalFaces = 0;
  var unnamed = 0;
  var tiny = 0;
  var belowThreshold = 0;
  var ambiguousMargin = 0;
  var wouldMatch = 0;
  final examples = <String>[];

  for (final entry in entries.values) {
    for (var i = 0; i < entry.faces.length; i++) {
      final f = entry.faces[i];
      totalFaces++;
      if (f.name != null || f.ignored) continue;
      unnamed++;
      final area = f.rect.width * f.rect.height;
      if (area < kMinAutoFaceArea) {
        tiny++;
        continue;
      }
      // Best identity + runner-up, with the matcher's threshold logic.
      String? bestName;
      var bestScore = 0.0;
      var runnerUp = 0.0;
      for (final id in ids) {
        final s = matcher.scoreFor(f.embedding, id);
        if (bestName == null || s > bestScore) {
          if (bestName != null && bestScore > runnerUp) runnerUp = bestScore;
          bestScore = s;
          bestName = id.name;
        } else if (s > runnerUp) {
          runnerUp = s;
        }
      }
      if (bestName == null) continue;
      final id = matcher.identityFor(bestName);
      final bonus = ((id.faceSamples - 1) * 0.01).clamp(0.0, 0.05);
      final threshold = kDefaultFaceMatchThreshold - bonus;
      final resolved = matcher.match(f.embedding);
      if (resolved != null) {
        wouldMatch++;
        if (examples.length < 12) {
          examples.add('  WOULD MATCH: $resolved '
              'score=${bestScore.toStringAsFixed(3)} '
              'runner=${runnerUp.toStringAsFixed(3)} thr=${threshold.toStringAsFixed(3)} '
              'link=${entry.linkId} face=\$i');
        }
      } else if (bestScore < threshold) {
        belowThreshold++;
      } else if (bestScore - runnerUp < kFaceMatchMargin) {
        ambiguousMargin++;
        if (examples.length < 20) {
          examples.add('  AMBIGUOUS: best=$bestName '
              'score=${bestScore.toStringAsFixed(3)} '
              'runner=${runnerUp.toStringAsFixed(3)} '
              'margin=${(bestScore - runnerUp).toStringAsFixed(3)} '
              'link=${entry.linkId} face=\$i');
        }
      }
    }
  }

  stderr.writeln('probe: photos=${entries.length} faces=$totalFaces '
      'unnamed=$unnamed tiny=$tiny');
  stderr.writeln('probe: unnamed workable (non-tiny)=${unnamed - tiny}: '
      'wouldMatch=$wouldMatch belowThreshold=$belowThreshold '
      'ambiguousMargin=$ambiguousMargin');
  for (final e in examples) {
    stderr.writeln(e);
  }
  exit(0);
}
