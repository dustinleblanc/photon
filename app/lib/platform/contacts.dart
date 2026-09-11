import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A device contact shown in the picker.
@immutable
class PhoneContact {
  const PhoneContact({
    required this.id,
    required this.name,
    this.phone,
    this.photoUri,
  });

  final String id;
  final String name;
  final String? phone;
  final String? photoUri;

  factory PhoneContact.fromMap(Map<Object?, Object?> map) => PhoneContact(
        id: map['id'] as String? ?? '',
        name: map['name'] as String? ?? '',
        phone: map['phone'] as String?,
        photoUri: map['photoUri'] as String?,
      );
}

const _channel = MethodChannel('com.dustinleblanc.photon.library/contacts');

/// Requests READ_CONTACTS. Returns true once granted.
Future<bool> requestContactsPermission() async {
  if (!Platform.isAndroid) return false;
  // The native side shows the system prompt when READ_CONTACTS is missing, so
  // we trigger an empty search and observe the outcome.
  try {
    await _channel.invokeMethod<List<Object?>>('search', {
      'query': '',
    });
    return true;
  } on PlatformException catch (e) {
    if (e.code == 'PERMISSION_DENIED') return false;
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Searches contacts by display name (case-insensitive substring). An empty
/// query returns an alphabetised sample of the address book.
Future<List<PhoneContact>> searchContacts(String query) async {
  if (!Platform.isAndroid) return const [];
  try {
    final raw = await _channel.invokeListMethod<Object?>('search', {
      'query': query,
    });
    final results = raw ?? const [];
    return results
        .whereType<Map<Object?, Object?>>()
        .map(PhoneContact.fromMap)
        .toList();
  } on PlatformException catch (e) {
    if (e.code == 'PERMISSION_DENIED') return const [];
    return const [];
  } on MissingPluginException {
    return const [];
  }
}

/// Fetches a contact's photo (or thumbnail) as JPEG bytes, or null when the
/// contact has no photo.
Future<Uint8List?> contactPhoto(String id) async {
  if (!Platform.isAndroid || id.isEmpty) return null;
  try {
    final bytes = await _channel.invokeMethod<Uint8List?>('photo', {
      'id': id,
    });
    return bytes;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}