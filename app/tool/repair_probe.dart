import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

/// Runs repairIdentities on a COPY of the real index and reports the effect
/// on the worst identities. Safe: the live index is untouched.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final key = base64Decode(
      File('${support.path}/photon_ml_index.key').readAsStringSync().trim());
  final tmp = await Directory.systemTemp.createTemp('photon_repair_probe');
  for (final name in ['detections_v1.hive', 'identities_v1.hive']) {
    final src = File('${support.path}/$name');
    if (src.existsSync()) src.copySync('${tmp.path}/$name');
  }

  final index = DetectionIndex();
  await index.init(dirOverride: tmp, keyOverride: key);

  void report(String label) {
    for (final target in ['Ali Costonis', 'Sadie LeBlanc']) {
      final local = <Float32List>[];
      for (final e in index.debugEntries().values) {
        for (final f in e.faces) {
          if (f.name == target && (f.similarity ?? 0) >= 1.0) local.add(f.embedding);
        }
      }
      var intra = 0.0;
      var pairs = 0;
      for (var i = 0; i < local.length; i++) {
        for (var j = i + 1; j < local.length; j++) {
          intra += faceMatchScore(local[i], local[j]);
          pairs++;
        }
      }
      stderr.writeln('$label ${target.padRight(15)} samples=${local.length} '
          'cohesion=${pairs == 0 ? '-' : (intra / pairs).toStringAsFixed(3)}');
    }
  }

  report('before:');
  final result = await index.repairIdentities();
  stderr.writeln('repair: identitiesRepaired=${result.identitiesRepaired} '
      'facesCleared=${result.facesCleared}');
  report('after: ');

  await index.dispose();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  exit(0);
}
