import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:photon_library/ml/detection_index.dart';

/// Verifies the reset/clear operations on a COPY of the real index, so the
/// live data is untouched. Run:
///   flutter run -d macos -t tool/reset_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final realKeyFile = File('${support.path}/photon_ml_index.key');
  if (!realKeyFile.existsSync()) {
    stderr.writeln('probe: no index key found at ${realKeyFile.path}');
    exit(1);
  }
  final key = base64Decode(realKeyFile.readAsStringSync().trim());

  // Copy the Hive files into a temp dir and operate there.
  final tmp = await Directory.systemTemp.createTemp('photon_reset_probe');
  for (final name in ['detections_v1.hive', 'identities_v1.hive']) {
    final src = File('${support.path}/$name');
    if (src.existsSync()) src.copySync('${tmp.path}/$name');
  }

  final index = DetectionIndex();
  await index.init(dirOverride: tmp, keyOverride: key);
  stderr.writeln('probe: opened copy available=${index.available} '
      'entries=${index.debugEntries().length} identities=${index.identities.length}');

  final cleared = await index.clearAllFaces();
  stderr.writeln('probe: clearAllFaces removed=$cleared '
      'entriesAfter=${index.debugEntries().length} '
      'identitiesAfter=${index.identities.length} '
      'facesOnFirstEntry=${index.debugEntries().values.isEmpty ? '-' : index.debugEntries().values.first.faces.length}');

  final removed = await index.resetIndex();
  stderr.writeln('probe: resetIndex removed=$removed '
      'entriesAfter=${index.debugEntries().length} '
      'identitiesAfter=${index.identities.length}');

  await index.dispose();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  exit(0);
}
