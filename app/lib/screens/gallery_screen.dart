import 'package:flutter/cupertino.dart';

import '../state/app_state.dart';
import 'lightbox_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.state});

  final AppState state;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 800) {
      widget.state.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Photon Library'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => widget.state.logout(),
          child: const Icon(CupertinoIcons.escape),
        ),
      ),
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          if (widget.state.error != null) {
            return _ErrorView(
              message: widget.state.error!,
              onRetry: () => widget.state.loadMore(),
            );
          }
          if (widget.state.photos.isEmpty && widget.state.loading) {
            return const Center(child: CupertinoActivityIndicator());
          }
          if (widget.state.photos.isEmpty) {
            return const Center(child: Text('No photos yet.'));
          }
          return GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount:
                widget.state.photos.length + (widget.state.hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= widget.state.photos.length) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CupertinoActivityIndicator(radius: 12),
                  ),
                );
              }
              final photo = widget.state.photos[index];
              return _PhotoTile(
                state: widget.state,
                linkId: photo.linkId,
                onTap: () => _openLightbox(index),
              );
            },
          );
        },
      ),
    );
  }

  void _openLightbox(int index) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => LightboxScreen(
          state: widget.state,
          initialIndex: index,
        ),
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.state,
    required this.linkId,
    required this.onTap,
  });

  final AppState state;
  final String linkId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FutureBuilder(
        future: state.preview(linkId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          }
          final theme = CupertinoTheme.of(context);
          return ColoredBox(
            color: theme.scaffoldBackgroundColor.withValues(alpha: 0.04),
            child: Center(
              child: snapshot.hasError
                  ? Icon(
                      CupertinoIcons.photo_on_rectangle,
                      color: theme.primaryColor.withValues(alpha: 0.6),
                    )
                  : const CupertinoActivityIndicator(radius: 10),
            ),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            CupertinoButton.filled(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}