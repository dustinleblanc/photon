import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

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
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0x66000000),
        border: null,
        leading: CupertinoNavigationBarBackButton(
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: Text(
          '${_index + 1} / $count',
          style: const TextStyle(color: CupertinoColors.white),
        ),
      ),
      child: PageView.builder(
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
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Failed to load original'),
          content: Text('$e'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingOriginal = false);
    }
  }

  final Color _white70 = const Color(0xB3FFFFFF);

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
                          errorBuilder: (_, _, _) => Center(
                            child: Text(
                              'Preview unavailable',
                              style: TextStyle(color: _white70),
                            ),
                          ),
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Could not load preview',
                          style: TextStyle(color: _white70),
                        ),
                      );
                    }
                    return const Center(child: CupertinoActivityIndicator());
                  },
                ),
        ),
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Center(
            child: CupertinoButton.filled(
              onPressed: _loadingOriginal ? null : _loadOriginal,
              child: _loadingOriginal
                  ? const CupertinoActivityIndicator()
                  : Text(_original != null ? 'Original loaded' : 'Load original'),
            ),
          ),
        ),
      ],
    );
  }
}