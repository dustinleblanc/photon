import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../ml/detection.dart';
import '../ml/detection_index.dart';
import '../ml/library_scanner.dart';
import '../state/app_state.dart';
import 'lightbox_screen.dart';
import 'people_screen.dart';
import 'settings_screen.dart';
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.state});

  final AppState state;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();
  DetectionGroup? _filter;
  String? _personName;

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

  void _toggleScan() {
    final scanner = widget.state.detector;
    if (scanner.running) {
      scanner.cancel();
      return;
    }
    final linkIds = widget.state.photos.map((p) => p.linkId).toList();
    scanner.start(linkIds);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final index = state.detectionIndex;
    final scanner = state.detector;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(_personName ?? 'Photon Library'),
        leading: _personName != null
            ? BackButton(
                onPressed: () => setState(() {
                  _filter = null;
                  _personName = null;
                }),
              )
            : null,
        actions: [
          IconButton(
            tooltip: scanner.running ? 'Stop scanning' : 'Scan for objects',
            icon: Icon(scanner.running ? Icons.stop : Icons.psychology),
            onPressed: _toggleScan,
          ),
          if (Platform.isAndroid)
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(state: widget.state),
                ),
              ),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([state, index, scanner]),
        builder: (context, _) {
          final photos = state.photos;
          if (state.error != null) {
            return _ErrorView(
              message: state.error!,
              onRetry: () => state.loadMore(),
            );
          }
          if (photos.isEmpty && state.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (photos.isEmpty) {
            return const Center(child: Text('No photos yet.'));
          }

          final filtered = [
            for (final p in photos)
              if (_matches(index, p.linkId)) p,
          ];

          return Column(
            children: [
              if (scanner.running) _ScanProgress(scanner: scanner),
              _FilterBar(
                selected: _filter,
                personName: _personName,
                scannedCount: index.scannedCount,
                onSelected: (g) => setState(() {
                  _filter = g;
                  _personName = null;
                }),
                onPeople: _showPeopleSheet,
              ),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyFilter(
                        group: _filter,
                        personName: _personName,
                                scannedCount: index.scannedCount,
                        onScan: _filter == null && _personName == null
                            ? null
                            : _toggleScan,
                      )
                    : GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(2),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                            ),
                        itemCount:
                            filtered.length + (state.hasMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= filtered.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final photo = filtered[i];
                          return _PhotoTile(
                            state: state,
                            linkId: photo.linkId,
                            onTap: () => _openLightbox(photo),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _matches(DetectionIndex index, String linkId) {
    if (_personName != null) return index.peopleFor(linkId).contains(_personName);
    if (_filter != null) return index.groupsFor(linkId).contains(_filter);
    return true;
  }

  Future<void> _showPeopleSheet() async {
    // Refresh from other devices before showing, so newly tagged people
    // from the phone are already here.
    unawaited(widget.state.tagsSync.pullAndPush());
    final selection = await Navigator.of(context).push<PeopleSelection>(
      MaterialPageRoute(builder: (_) => PeopleScreen(state: widget.state)),
    );
    if (selection == null || !mounted) return;
    setState(() {
      _filter = null;
      _personName = selection.name;
    });
  }

  void _openLightbox(Photo photo) {
    final index =
        widget.state.photos.indexWhere((p) => p.linkId == photo.linkId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LightboxScreen(
          state: widget.state,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
  }
}

class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.scanner});

  final LibraryScanner scanner;

  @override
  Widget build(BuildContext context) {
    final progress = scanner.progress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(
          value: progress,
          minHeight: 2,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              scanner.cancelRequested
                  ? 'Stopping…'
                  : 'Scanning ${scanner.processed}/${scanner.total}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.selected,
    required this.personName,
    required this.scannedCount,
    required this.onSelected,
    required this.onPeople,
  });

  final DetectionGroup? selected;
  final String? personName;
  final int scannedCount;
  final ValueChanged<DetectionGroup?> onSelected;
  final VoidCallback onPeople;

  @override
  Widget build(BuildContext context) {
    final personActive = personName != null;
    final chips = <Widget>[
      Padding(
        padding: const EdgeInsets.only(left: 12),
        child: FilterChip(
          label: const Text('All'),
          selected: !personActive && selected == null,
          onSelected: (_) => onSelected(null),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: FilterChip(
          avatar: const Icon(Icons.face, size: 18),
          label: Text(
            personName ?? 'People',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          selected: personActive,
          onSelected: (_) => onPeople(),
          tooltip: 'Filter by person',
        ),
      ),
      for (final g in DetectionGroup.values)
        if (g != DetectionGroup.people) ...[
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: FilterChip(
              avatar: Icon(g.icon, size: 18),
              label: Text(g.label),
              selected: !personActive && selected == g,
              onSelected: (_) => onSelected(g),
            ),
          ),
        ],
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 4, runSpacing: 4, children: chips),
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

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({
    this.group,
    this.personName,
    required this.scannedCount,
    required this.onScan,
  });

  final DetectionGroup? group;
  final String? personName;
  final int scannedCount;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    if (scannedCount == 0 && (group != null || personName != null)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No photos scanned yet.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.psychology),
              label: const Text('Scan library'),
            ),
          ],
        ),
      );
    }
    final message = personName != null
        ? 'No photos of $personName yet.'
        : 'No ${group?.label.toLowerCase()} photos yet.';
    return Center(child: Text(message));
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

