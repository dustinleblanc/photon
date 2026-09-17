import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

/// Diagnoses identity quality: duplicate/overlapping identities (which cause
/// ambiguity rejections), zero/weak centroids (which cause misses), and
/// sample cohesion (contaminated samples cause both misses and bad matches).
///   flutter run -d macos -t tool/identities_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();
  final ids = index.identities;
  final entries = index.debugEntries();

  // Gather confirmed samples per identity.
  final samples = <String, List<Float32List>>{};
  for (final e in entries.values) {
    for (final f in e.faces) {
      final n = f.name;
      if (n == null || f.ignored) continue;
      if ((f.similarity ?? 0) < 1.0) continue;
      (samples[n] ??= []).add(f.embedding);
    }
  }

  stderr.writeln('identities: ${ids.length}');
  stderr.writeln('--- per identity: samples, centroid norm, cohesion ---');
  for (final id in ids) {
    final list = samples[id.name] ?? const <Float32List>[];
    var norm = 0.0;
    for (final v in id.centroid) {
      norm += v * v;
    }
    norm = sqrt(norm);
    // Mean similarity of each sample to the centroid, and to each other.
    var toCentroid = 0.0;
    for (final s in list) {
      toCentroid += faceMatchScore(s, id.centroid);
    }
    if (list.isNotEmpty) toCentroid /= list.length;
    var intra = 0.0;
    var pairs = 0;
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        intra += faceMatchScore(list[i], list[j]);
        pairs++;
      }
    }
    if (pairs > 0) intra /= pairs;
    stderr.writeln('  ${id.name.padRight(20)} storedSamples=${id.faceSamples} '
        'localSamples=${list.length} centroidNorm=${norm.toStringAsFixed(2)} '
        'sampleToCentroid=${list.isEmpty ? '-' : toCentroid.toStringAsFixed(3)} '
        'intraCohesion=${pairs == 0 ? '-' : intra.toStringAsFixed(3)}');
  }

  stderr.writeln('--- identity pairs with similar centroids (ambiguity risk) ---');
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final s = faceMatchScore(ids[i].centroid, ids[j].centroid);
      if (s >= 0.5) {
        stderr.writeln('  ${ids[i].name} ~ ${ids[j].name} '
            'centroidSim=${s.toStringAsFixed(3)}');
      }
    }
  }
  exit(0);
}
