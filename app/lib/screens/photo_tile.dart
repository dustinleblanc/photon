import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

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

Future<img.Image?> decodedPreviewFor(AppState state, String linkId) async {
  if (decodedPreviewCache.containsKey(linkId)) {
    return decodedPreviewCache[linkId];
  }
  img.Image? decoded;
  try {
    final bytes = await state.preview(linkId, size: 800);
    decoded = img.decodeImage(bytes);
  } catch (_) {}
  decodedPreviewCache[linkId] = decoded;
  return decoded;
}
