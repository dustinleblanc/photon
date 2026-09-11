import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/contacts.dart';

/// Sentinel returned by the "Who is this?" dialog when the user chooses
/// "Link a contact…" instead of typing a manual name.
const String kLinkContact = '__link__';

/// Lets the user pick a device contact, optionally searching first.
///
/// Handles the READ_CONTACTS runtime prompt. Returns null when cancelled or
/// when permission is denied.
class ContactPicker {
  ContactPicker._();

  static Future<PhoneContact?> pick(BuildContext context) {
    return showDialog<PhoneContact>(
      context: context,
      builder: (dialogContext) => const _ContactPickerDialog(),
    );
  }
}

class _ContactPickerDialog extends StatefulWidget {
  const _ContactPickerDialog();

  @override
  State<_ContactPickerDialog> createState() => _ContactPickerDialogState();
}

class _ContactPickerDialogState extends State<_ContactPickerDialog> {
  List<PhoneContact>? _contacts;
  bool _permissionDenied = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load(String query) async {
    var results = await searchContacts(query);
    if (!mounted) return;
    if (results.isEmpty) {
      final granted = await requestContactsPermission();
      if (!granted) {
        if (!mounted) return;
        setState(() {
          _permissionDenied = true;
          _contacts = const [];
        });
        return;
      }
      results = await searchContacts(query);
    }
    if (!mounted) return;
    setState(() {
      _permissionDenied = false;
      _contacts = results;
    });
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _load(value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Link a contact'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: _contacts != null,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Search contacts…',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            if (_permissionDenied)
              const Expanded(
                child: Center(
                  child: Text(
                    'Reading contacts is needed to link a person.\n'
                    'Allow access in Settings to use this.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (_contacts == null)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_contacts!.isEmpty)
              const Expanded(
                child: Center(child: Text('No contacts match.')),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _contacts!.length,
                  itemBuilder: (context, i) {
                    final c = _contacts![i];
                    return ListTile(
                      leading: ContactAvatar(contact: c, radius: 20),
                      title: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: c.phone == null || c.phone!.isEmpty
                          ? null
                          : Text(c.phone!),
                      onTap: () => Navigator.pop(context, c),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Contact avatar: resolves the photo through [the platform layer] with a
/// shared per-id cache so the same linked person doesn't re-read the device
/// in every photo.
class ContactAvatar extends StatefulWidget {
  const ContactAvatar({
    super.key,
    required this.contact,
    this.radius = 16,
  });

  final PhoneContact contact;
  final double radius;

  @override
  State<ContactAvatar> createState() => _ContactAvatarState();
}

class _ContactAvatarState extends State<ContactAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!Platform.isAndroid) return;
    final cached = _photoCache[widget.contact.id];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    final bytes = await contactPhoto(widget.contact.id);
    if (bytes != null) _photoCache[widget.contact.id] = bytes;
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ?? _photoCache[widget.contact.id];
    return CircleAvatar(
      radius: widget.radius,
      foregroundImage: bytes == null ? null : MemoryImage(bytes),
      child: Text(
        widget.contact.name.isEmpty
            ? '?'
            : widget.contact.name[0].toUpperCase(),
        style: TextStyle(fontSize: widget.radius * 0.9),
      ),
    );
  }
}

/// contact id -> JPEG bytes, shared app-wide.
final Map<String, Uint8List> _photoCache = {};