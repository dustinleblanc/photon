import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../ml/detection.dart';
import '../ml/detection_index.dart';
import '../ml/library_scanner.dart';
import '../state/app_state.dart';
import 'lightbox_screen.dart';
import 'login_screen.dart';
import 'photo_tile.dart';
import 'settings_screen.dart';
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    required this.state,
    this.embedded = false,
    this.groups,
    this.label,
  });

  /// True when hosted inside the app shell, which supplies the app bar and
  /// the navigation menu.
  final bool embedded;

  /// Detection groups to show; null means every photo. Ignored when [label]
  /// is set.
  final Set<DetectionGroup>? groups;

  /// A specific detected object label to show (e.g. "motorcycle"), reached
  /// through search. Null when filtering by group or showing everything.
  final String? label;

  final AppState state;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();
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
          if (photos.isEmpty && state.needsReconnect) {
            return _ReconnectView(state: state);
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
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyFilter(
                        label: widget.label,
                        groups: widget.groups,
                        scannedCount: index.scannedCount,
                        onScan: widget.label == null && widget.groups == null
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
    final label = widget.label;
    if (label != null) return index.hasLabel(linkId, label);
    final groups = widget.groups;
    if (groups != null) {
      for (final g in groups) {
        if (index.hasGroup(linkId, g)) return true;
      }
      return false;
    }
    return true;
  }

  /// Filters run over the loaded photo list, so while the library is only
  /// partially loaded a filtered grid undercounts (the People tile counts
  /// from the full index) and — with too few matches to scroll — never
  /// triggers the pagination listener, leaving a spinner forever. Whenever a
  /// filter is active and pages remain, keep fetching in the background.
  void _loadRemainingForFilter() {
    if ((widget.label == null && widget.groups == null) ||
        !widget.state.hasMore ||
        widget.state.loading) {
      return;
    }
    unawaited(
      widget.state.loadAll().catchError((_) {}),
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


class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({
    this.label,
    this.groups,
    required this.scannedCount,
    required this.onScan,
  });

  final String? label;
  final Set<DetectionGroup>? groups;
  final int scannedCount;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    if (scannedCount == 0 && (label != null || groups != null)) {
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
    final message = label != null
        ? 'No photos with “$label” yet.'
        : 'No ${groups!.first.label.toLowerCase()} photos yet.';
    return Center(child: Text(message));
  }
}

/// Shown when this device has an account but its Proton session can't be
/// resumed (expired or signed out). Local content still works; this only
/// gates fetching new photos.
class _ReconnectView extends StatelessWidget {
  const _ReconnectView({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Not connected to Proton',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Your people, tags and cached previews are still available. '
              'Sign in to load the rest of the library.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(
                  builder: (_) => LoginScreen(state: state),
                ),
              ),
              icon: const Icon(Icons.login),
              label: const Text('Sign in'),
            ),
          ],
        ),
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

