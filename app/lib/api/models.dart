class Photo {
  const Photo({
    required this.linkId,
    required this.captureTime,
    this.addedTime,
    this.hash = '',
    this.contentHash = '',
    this.tags = const [],
    this.relatedPhotos = const [],
  });

  final String linkId;
  final int captureTime;
  final int? addedTime;
  final String hash;
  final String contentHash;
  final List<int> tags;
  final List<Photo> relatedPhotos;

  factory Photo.fromJson(Map<String, dynamic> json) {
    return Photo(
      linkId: json['linkId'] as String,
      captureTime: (json['captureTime'] as num).toInt(),
      addedTime: (json['addedTime'] as num?)?.toInt(),
      hash: (json['hash'] as String?) ?? '',
      contentHash: (json['contentHash'] as String?) ?? '',
      tags: ((json['tags'] as List?) ?? const [])
          .map((e) => (e as num).toInt())
          .toList(),
      relatedPhotos: ((json['relatedPhotos'] as List?) ?? const [])
          .map((e) => Photo.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AssetsPage {
  const AssetsPage({required this.assets, this.nextCursor});

  final List<Photo> assets;
  final String? nextCursor;
}

class SessionStatus {
  const SessionStatus({required this.authenticated});

  final bool authenticated;

  factory SessionStatus.fromJson(Map<String, dynamic> json) {
    return SessionStatus(authenticated: json['authenticated'] == true);
  }
}

enum LoginOutcome { ok, hvRequired, error }

class LoginResult {
  const LoginResult({required this.outcome, this.hvToken, this.hvMethods, this.error});

  final LoginOutcome outcome;
  final String? hvToken;
  final List<String>? hvMethods;
  final String? error;

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String?;
    return LoginResult(
      outcome: switch (status) {
        'ok' => LoginOutcome.ok,
        'hv_required' => LoginOutcome.hvRequired,
        _ => LoginOutcome.error,
      },
      hvToken: json['hvToken'] as String?,
      hvMethods: ((json['hvMethods'] as List?) ?? const [])
          .map((e) => e as String)
          .toList(),
      error: json['error'] as String?,
    );
  }
}