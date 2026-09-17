import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';

/// Histogram of stored similarity for every named (non-manual) face, to show
/// how many matches sit just above the threshold.
///   flutter run -d macos -t tool/bands_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();
  var manual = 0, auto = 0;
  final bands = <String, int>{};
  for (final e in index.debugEntries().values) {
    for (final f in e.faces) {
      if (f.name == null) continue;
      final sim = f.similarity;
      if (sim == null || sim >= 1.0) {
        manual++;
        continue;
      }
      auto++;
      final b = sim >= 0.85
          ? '>=0.85'
          : sim >= 0.80
              ? '0.80-0.85'
              : sim >= 0.75
                  ? '0.75-0.80'
                  : sim >= 0.70
                      ? '0.70-0.75'
                      : sim >= 0.65
                          ? '0.65-0.70'
                          : sim >= 0.60
                              ? '0.60-0.65'
                              : '<0.60';
      bands[b] = (bands[b] ?? 0) + 1;
    }
  }
  stderr.writeln('bands: manual=$manual auto=$auto');
  stderr.writeln('bands: $bands');
  exit(0);
}
