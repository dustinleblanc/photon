import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../platform/gallery.dart';
import '../state/app_state.dart';
import 'people_panel.dart';

class LightboxScreen extends StatefulWidget {
  const LightboxScreen({
    super.key,
    required this.state,
    required this.initialIndex,
  });

  final AppState state;
  final int initialIndex;

  @override
  State<LightboxScreen> createState() => _LightboxScreenState();
}

class _LightboxScreenState extends State<LightboxScreen> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.state.photos.length;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black45,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / $count'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: count,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => _LightboxPage(
          state: widget.state,
          linkId: widget.state.photos[i].linkId,
        ),
      ),
    );
  }
}

class _LightboxPage extends StatefulWidget {
  const _LightboxPage({required this.state, required this.linkId});

  final AppState state;
  final String linkId;

  @override
  State<_LightboxPage> createState() => _LightboxPageState();
}

class _LightboxPageState extends State<_LightboxPage> {
  Uint8List? _original;
  bool _busy = false;

  Future<void> _loadOriginal() async {
    await _ensureOriginal();
  }

  Future<Uint8List?> _ensureOriginal() async {
    final existing = _original;
    if (existing != null) return existing;
    setState(() => _busy = true);
    try {
      final bytes = await widget.state.original(widget.linkId);
      if (mounted) setState(() => _original = bytes);
      return bytes;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load original: $e')));
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _stampName() =>
      'photon_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.jpg';

  void _showActions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (Platform.isAndroid) ...[
                ListTile(
                  leading: const Icon(Icons.wallpaper),
                  title: const Text('Set as wallpaper'),
                  enabled: !_busy,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setAsWallpaper();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.save_alt),
                  title: const Text('Save to gallery'),
                  enabled: !_busy,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _saveToGallery();
                  },
                ),
                if (Platform.isAndroid)
                  ListTile(
                    leading: const Icon(Icons.face),
                    title: const Text('People'),
                    enabled: !_busy,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showPeople();
                    },
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Share'),
                enabled: !_busy,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _share();
                },
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: Text(
                  _original != null ? 'Original downloaded' : 'Download original',
                ),
                enabled: !_busy && _original == null,
                trailing: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _loadOriginal();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showPeople() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => PeoplePanel(state: widget.state, linkId: widget.linkId),
    );
  }

  Future<void> _share() async {
    if (_busy) return;
    final bytes = await _ensureOriginal();
    if (bytes == null || !mounted) return;
    final name = _stampName();
    final tmp = File('${Directory.systemTemp.path}/$name');
    await tmp.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(tmp.path)], subject: name),
    );
    tmp.delete();
  }

  Future<void> _setAsWallpaper() async {
    if (_busy) return;
    final bytes = await _ensureOriginal();
    if (bytes == null || !mounted) return;
    final ok = await setAsWallpaper(bytes, _stampName());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Opening wallpaper picker' : 'Could not set as wallpaper'),
      ),
    );
  }

  Future<void> _saveToGallery() async {
    if (_busy) return;
    final bytes = await _ensureOriginal();
    if (bytes == null || !mounted) return;
    final ok = await saveImageToGallery(bytes, _stampName());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Saved to gallery' : 'Could not save to gallery'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          maxScale: 6,
          child: _original != null
              ? Image.memory(_original!, fit: BoxFit.contain)
              : FutureBuilder(
                  future: widget.state.preview(widget.linkId, size: 1600),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        snapshot.hasData) {
                      return Center(
                        child: Image.memory(
                          snapshot.data!,
                          fit: BoxFit.contain,
errorBuilder: (_, _, _) =>
                            const Center(child: Text('Preview unavailable')),
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      return const Center(
                        child: Text(
                          'Could not load preview',
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  },
                ),
        ),
        Positioned(
          bottom: 20,
          left: 0,
          right: 0,
          child: Center(
            child: _busy
                ? Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(11),
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Material(
                    color: Colors.black45,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: 'Actions',
                      onPressed: _showActions,
                      icon: const Icon(Icons.more_horiz, color: Colors.white),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}