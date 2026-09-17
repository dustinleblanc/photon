import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ml/faces.dart';
import '../state/app_state.dart';

/// One photo thumbnail. Shared by the main gallery and the person page so
/// both look and behave identically (memoized preview so rebuilds don't
/// flash the placeholder).
class PhotoTile extends StatefulWidget {
  const PhotoTile({
    super.key,
    required this.state,
    required this.linkId,
    required this.onTap,
  });

  final AppState state;
  final String linkId;
  final VoidCallback onTap;

  @override
  State<PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<PhotoTile> {
  late Future<Uint8List> _preview;

  @override
  void initState() {
    super.initState();
    _preview = widget.state.preview(widget.linkId);
  }

  @override
  void didUpdateWidget(covariant PhotoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.linkId != widget.linkId || oldWidget.state != widget.state) {
      _preview = widget.state.preview(widget.linkId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      child: FutureBuilder(
        future: _preview,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          }
          final theme = Theme.of(context);
          return Container(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Center(
              child: snapshot.hasError
                  ? Icon(
                      Icons.broken_image_outlined,
                      color: theme.colorScheme.outline,
                    )
                  : const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            ),
          );
        },
      ),
    );
  }
}

/// Decoded preview cache shared by all tiles: one fetch per source photo no
/// matter how many people appear in it.
final Map<String, img.Image?> decodedPreviewCache = {};

Future<img.Image?> decodedPreviewFor(
  AppState state,
  String linkId, {
  int size = 512,
}) async {
  final key = '$linkId@$size';
  if (decodedPreviewCache.containsKey(key)) {
    return decodedPreviewCache[key];
  }
  img.Image? decoded;
  try {
    // 512 is the cheap server tier: requesting more serves the 1920px HD
    // preview, which is needlessly slow to decrypt and decode for a tile.
    final bytes = await state.preview(linkId, size: size);
    decoded = img.decodeImage(bytes);
  } catch (_) {}
  decodedPreviewCache[key] = decoded;
  return decoded;
}

/// A face-crop thumbnail, persisted in the encrypted cache. The key folds in
/// the source photo and the face rect so the crop can be reused across
/// launches without re-fetching or re-decoding the preview.
Future<Uint8List?> faceThumb(
  AppState state,
  String linkId,
  Rect rect, {
  int size = 200,
}) async {
  final rectKey = '${rect.left.toStringAsFixed(3)},'
      '${rect.top.toStringAsFixed(3)},'
      '${rect.right.toStringAsFixed(3)},'
      '${rect.bottom.toStringAsFixed(3)}';
  final key = 'face|$linkId|$rectKey|$size';
  // Memory first: returning the SAME Uint8List lets Flutter's image cache
  // reuse the decoded bitmap, and avoids re-decrypting from disk on every
  // rebuild (which made scrolling jittery).
  final memory = faceThumbCache[key];
  if (memory != null) return memory;
  final cached = await state.cachedThumb(key, size);
  if (cached != null) {
    _rememberThumb(key, cached);
    return cached;
  }
  final decoded = await decodedPreviewFor(state, linkId);
  if (decoded == null) return null;
  final bytes = cropFaceJpegFromDecoded(decoded, rect, size: size);
  if (bytes.isNotEmpty) {
    _rememberThumb(key, bytes);
    unawaited(state.putThumb(key, size, bytes));
  }
  return bytes;
}

void _rememberThumb(String key, Uint8List bytes) {
  faceThumbCache[key] = bytes;
  if (faceThumbCache.length > _faceThumbCacheCap) {
    faceThumbCache.remove(faceThumbCache.keys.first);
  }
}

/// In-memory face-crop thumbnails, keyed like the on-disk cache. Keeps the
/// byte identity stable so Flutter reuses decoded bitmaps, and caps memory.
final Map<String, Uint8List> faceThumbCache = {};
const int _faceThumbCacheCap = 600;
