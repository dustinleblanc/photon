import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:photon_library/sidecar/sidecar.dart';

void main() {
  group('findRepoRoot', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('photon_repo_root_');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('finds the nearest ancestor containing go.mod and core/', () {
      File('${temp.path}/go.mod').writeAsStringSync('module photon');
      Directory('${temp.path}/core').createSync();
      final nested = Directory('${temp.path}/a/b')
        ..createSync(recursive: true);

      expect(findRepoRoot(nested), temp.path);
    });

    test('returns null instead of looping at the filesystem root', () {
      final nested = Directory('${temp.path}/a/b')
        ..createSync(recursive: true);

      // Regression: Directory('/').parent == '/', so the walk must stop
      // explicitly rather than spin forever statting "/go.mod".
      expect(findRepoRoot(nested), isNull);
    });

    test('requires core/ alongside go.mod', () {
      File('${temp.path}/go.mod').writeAsStringSync('module photon');

      expect(findRepoRoot(temp), isNull);
    });
  });
}
