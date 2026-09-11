import 'package:flutter/material.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photon Library'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => widget.state.logout(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          if (widget.state.error != null) {
            return _ErrorView(
              message: widget.state.error!,
              onRetry: () => widget.state.loadMore(),
            );
          }
          if (widget.state.photos.isEmpty && widget.state.loading) {
            return const Center(child: CircularProgressIndicator());
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
            itemCount: widget.state.photos.length + (widget.state.hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= widget.state.photos.length) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
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
      MaterialPageRoute(
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
    return InkWell(
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
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}