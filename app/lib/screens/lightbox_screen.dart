import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

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
  bool _loadingOriginal = false;

  Future<void> _loadOriginal() async {
    setState(() => _loadingOriginal = true);
    try {
      final bytes = await widget.state.original(widget.linkId);
      if (!mounted) return;
      setState(() => _original = bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load original: $e')));
    } finally {
      if (mounted) setState(() => _loadingOriginal = false);
    }
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
          bottom: 24,
          left: 0,
          right: 0,
          child: Center(
            child: FilledButton.icon(
              onPressed: _loadingOriginal ? null : _loadOriginal,
              icon: _loadingOriginal
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_original != null ? 'Original loaded' : 'Load original'),
            ),
          ),
        ),
      ],
    );
  }
}