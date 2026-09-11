import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';

/// Dumps identities and per-face similarity detail. NAME env var filters one
/// person; LOW/SIM_HIGH bound the mis-tag audit band. Run:
///   flutter run -d macos -t tool/macos_index_dump.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();
  stderr.writeln('macos_index_dump: available=${index.available}');
  final ids = index.identities;
  stderr.writeln('macos_index_dump: ${ids.length} identities');
  for (final id in ids) {
    stderr.writeln(
      '  ${id.name} | aliases=${id.aliases} | samples=${id.faceSamples} '
      '| contact=${id.contactId ?? '-'}',
    );
  }
  final counts = index.countPeople();
  stderr.writeln('macos_index_dump: photo counts=$counts');

  final target = Platform.environment['NAME'] ?? 'Logan';
  final needle = target.toLowerCase();
  final low = double.tryParse(Platform.environment['LOW'] ?? '0.5');
  final high = double.tryParse(Platform.environment['SIM_HIGH'] ?? '0.65');

  final entries = index.debugEntries();
  stderr.writeln('macos_index_dump: faces named like "$target":');
  var i = 0;
  for (final entry in entries.values) {
    for (var f = 0; f < entry.faces.length; f++) {
      final face = entry.faces[f];
      final name = face.name?.toLowerCase();
      if (name == null || !name.contains(needle)) continue;
      stderr.writeln(
        '  [$i] ${entry.linkId} face=$f name=${face.name} '
        'sim=${face.similarity?.toStringAsFixed(3)} '
        'rect=(${face.rect.left.toStringAsFixed(4)}, '
        '${face.rect.top.toStringAsFixed(4)}, '
        '${face.rect.right.toStringAsFixed(4)}, '
        '${face.rect.bottom.toStringAsFixed(4)})',
      );
      i++;
    }
  }
  if (i == 0) stderr.writeln('  (none)');

  if (low != null && high != null) {
    stderr.writeln(
      'macos_index_dump: auto-assigned faces with sim in [$low, $high):',
    );
    var j = 0;
    for (final entry in entries.values) {
      for (var f = 0; f < entry.faces.length; f++) {
        final face = entry.faces[f];
        final sim = face.similarity;
        if (face.name == null || sim == null || sim >= high || sim < low) {
          continue;
        }
        stderr.writeln(
          '  [$j] ${entry.linkId} face=$f name=${face.name} '
          'sim=${sim.toStringAsFixed(3)} rect=${face.rect}',
        );
        j++;
      }
    }
    if (j == 0) stderr.writeln('  (none)');
  }
  exit(0);
}