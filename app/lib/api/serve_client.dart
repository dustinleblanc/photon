import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ServeClient {
  ServeClient({String url = 'http://127.0.0.1:8787'}) : _base = Uri.parse(url);

  final Uri _base;
  final HttpClient _http = HttpClient();

  void close() {
    _http.close(force: true);
  }

  Future<bool> health() async {
    try {
      final req = await _http.getUrl(_uri('/health'));
      final res = await req.close();
      final ok = res.statusCode == 200;
      await _drain(res);
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String? totp,
    String? hvToken,
    String? hvMethod,
  }) async {
    final body = jsonEncode({
      'username': username,
      'password': password,
      if (totp != null && totp.isNotEmpty) 'totp': totp,
      if (hvToken != null && hvToken.isNotEmpty) 'hvToken': hvToken,
      if (hvMethod != null && hvMethod.isNotEmpty) 'hvMethod': hvMethod,
    });
    final req = await _http.postUrl(_uri('/api/v1/auth/login'));
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close();
    return _readJson(res);
  }

  Future<void> logout() async {
    final req = await _http.postUrl(_uri('/api/v1/auth/logout'));
    req.headers.contentType = ContentType.json;
    req.write('{}');
    final res = await req.close();
    await _drain(res);
  }

  Future<bool> session() async {
    final req = await _http.getUrl(_uri('/api/v1/session'));
    final res = await req.close();
    final json = await _readJson(res);
    return SessionStatus.fromJson(json).authenticated;
  }

  Future<AssetsPage> listAssets({String? cursor, int pageSize = 200}) async {
    final query = <String, String>{
      'pageSize': '$pageSize',
      'cursor': ?cursor,
    };
    final req = await _http.getUrl(_uri('/api/v1/assets', query));
    final res = await req.close();
    final json = await _readJson(res);
    final rawAssets = (json['assets'] as List?) ?? const [];
    return AssetsPage(
      assets: rawAssets
          .map((e) => Photo.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: json['nextCursor'] as String?,
    );
  }

  Future<Uint8List> preview(String linkId, {int size = 512}) async {
    return _download(() async {
      final req = await _http.getUrl(
        _uri('/api/v1/assets/$linkId/preview', {'size': '$size'}),
      );
      final res = await req.close();
      return _readBytes(res);
    });
  }

  Future<Uint8List> original(String linkId) async {
    return _download(() async {
      final req = await _http.getUrl(_uri('/api/v1/assets/$linkId/original'));
      final res = await req.close();
      return _readBytes(res);
    });
  }

  /// Retries byte downloads on transient network failures. The serve streams
  /// large files (originals) through a tunnel, and a dropped keep-alive
  /// connection mid-body otherwise surfaces as "connection closed while
  /// receiving data".
  Future<Uint8List> _download(
    Future<Uint8List> Function() attempt, {
    int attempts = 3,
  }) async {
    Object? last;
    for (var i = 0; i < attempts; i++) {
      try {
        return await attempt();
      } on ApiException {
        rethrow;
      } catch (e) {
        last = e;
        if (i == attempts - 1) break;
        await Future<void>.delayed(Duration(milliseconds: 400 * (i + 1)));
      }
    }
    throw last! as Exception;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _base.toString().replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> _readJson(HttpClientResponse res) async {
    if (res.statusCode != 200) {
      final msg = await _errorMessage(res);
      throw ApiException(msg, statusCode: res.statusCode);
    }
    final body = await _collect(res);
    return jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
  }

  Future<Uint8List> _readBytes(HttpClientResponse res) async {
    if (res.statusCode != 200) {
      final msg = await _errorMessage(res);
      throw ApiException(msg, statusCode: res.statusCode);
    }
    return _collect(res);
  }

  Future<String> _errorMessage(HttpClientResponse res) async {
    final body = await _collect(res);
    try {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      return (json['error'] as String?) ?? 'HTTP ${res.statusCode}';
    } on FormatException {
      return 'HTTP ${res.statusCode}';
    }
  }

  Future<Uint8List> _collect(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _drain(HttpClientResponse res) async {
    await for (final _ in res) {
      // drain
    }
  }
}