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
import 'photo_tile.dart';
import 'settings_screen.dart';
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.state, this.embedded = false});

  /// True when hosted inside the desktop shell, which supplies the app bar.
  final bool embedded;

  final AppState state;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();
  DetectionGroup? _filter;
  bool _preparingScan = false;

  bool _wasScanning = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.state.detector.addListener(_onScannerChanged);
  }

  /// Scans used to fail silently (the error was stored but never shown).
  void _onScannerChanged() {
    final scanner = widget.state.detector;
    final running = scanner.running;
    if (_wasScanning && !running && mounted) {
      final error = scanner.error;
      final message = error != null
          ? 'Scan failed: $error'
          : scanner.scanned == 0
              ? 'Nothing to scan — ${scanner.total} photos already processed'
              : 'Scanned ${scanner.scanned} photos';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
    _wasScanning = running;
  }

  @override
  void dispose() {
    widget.state.detector.removeListener(_onScannerChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 800) {
      widget.state.loadMore();
    }
  }

  Future<void> _toggleScan() async {
    final scanner = widget.state.detector;
    if (scanner.running) {
      scanner.cancel();
      return;
    }
    if (_preparingScan) return;
    // Scan the entire library, not just the pages loaded into the gallery.
    setState(() => _preparingScan = true);
    try {
      final linkIds = await widget.state.libraryLinkIds();
      if (mounted) scanner.start(linkIds);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load the photo library: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _preparingScan = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final index = state.detectionIndex;
    final scanner = state.detector;
    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
        title: const Text('Photon Library'),
        actions: [
          ListenableBuilder(
            listenable: scanner,
            builder: (context, _) => IconButton(
              tooltip: scanner.running ? 'Stop scanning' : 'Scan for objects',
              icon: _preparingScan
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(scanner.running ? Icons.stop : Icons.psychology),
              onPressed: _preparingScan ? null : _toggleScan,
            ),
          ),
          if (Platform.isAndroid || Platform.isLinux)
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
        listenable: Listenable.merge([state, index]),
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
          _loadRemainingForFilter();

          // Computed once per build: the hidden set is the same for every
          // photo, and asking per photo re-decoded every identity.
          final hidden = index.hiddenNames;
          final filtered = [
            for (final p in photos)
              if (_matches(index, p.linkId, hidden)) p,
          ];

          return Column(
            children: [
              // Scan progress changes once per processed photo; keep it in its
              // own listener so it doesn't rebuild the photo grid. On desktop
              // the shell's top bar owns the progress meter, so this one is
              // only shown on mobile (non-embedded).
              if (!widget.embedded)
                ListenableBuilder(
                  listenable: scanner,
                  builder: (context, _) => scanner.running
                      ? _ScanProgress(scanner: scanner)
                      : const SizedBox.shrink(),
                ),
              _FilterBar(
                selected: _filter,
                scannedCount: index.scannedCount,
                onSelected: (g) => setState(() => _filter = g),
                onPeople: _showPeopleSheet,
              ),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyFilter(
                        group: _filter,
                        scannedCount: index.scannedCount,
                        onScan: _filter == null ? null : _toggleScan,
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
                          return PhotoTile(
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

  bool _matches(DetectionIndex index, String linkId, Set<String> hidden) {
    // Hidden people are kept out of the unfiltered and group views, so their
    // photos don't get surfaced unasked.
    if (index.hasAnyPerson(linkId, hidden)) return false;
    if (_filter != null) return index.hasGroup(linkId, _filter!);
    return true;
  }

  /// Filters run over the loaded photo list, so while the library is only
  /// partially loaded a filtered grid undercounts (the People tile counts
  /// from the full index) and — with too few matches to scroll — never
  /// triggers the pagination listener, leaving a spinner forever. Whenever a
  /// filter is active and pages remain, keep fetching in the background.
  void _loadRemainingForFilter() {
    if (_filter == null || !widget.state.hasMore || widget.state.loading) {
      return;
    }
    unawaited(
      widget.state.loadAll().catchError((_) {}),
    );
  }

  Future<void> _showPeopleSheet() {
    // The People page now owns per-person filtering and actions.
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PeopleScreen(state: widget.state)),
    );
  }

  void _openLightbox(Photo photo) {
    final index =
        widget.state.photos.indexWhere((p) => p.linkId == photo.linkId);
    Navigator.of(context, rootNavigator: true).push(
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
    required this.scannedCount,
    required this.onSelected,
    required this.onPeople,
  });

  final DetectionGroup? selected;
  final int scannedCount;
  final ValueChanged<DetectionGroup?> onSelected;
  final VoidCallback onPeople;

  @override
  Widget build(BuildContext context) {
    const personActive = false;
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
            'People',
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


class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({
    this.group,
    required this.scannedCount,
    required this.onScan,
  });

  final DetectionGroup? group;
  final int scannedCount;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    if (scannedCount == 0 && group != null) {
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
    final message = 'No ${group?.label.toLowerCase()} photos yet.';
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

