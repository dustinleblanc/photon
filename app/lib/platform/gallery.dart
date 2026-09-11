import 'dart:io';

import 'package:flutter/services.dart';

/// Saves image bytes into the Android MediaStore (Pictures/Photon Library).
///
/// Requires the Kotlin gallery MethodChannel in MainActivity. On non-Android
/// platforms this returns false without doing anything.
Future<bool> saveImageToGallery(Uint8List bytes, String filename) async {
  if (!Platform.isAndroid) return false;
  return _invoke('saveToGallery', bytes, filename);
}

/// Saves image bytes into the MediaStore and hands the resulting URI to the
/// system "set wallpaper" cropper (ACTION_ATTACH_DATA).
Future<bool> setAsWallpaper(Uint8List bytes, String filename) async {
  if (!Platform.isAndroid) return false;
  return _invoke('setAsWallpaper', bytes, filename);
}

Future<bool> _invoke(String method, Uint8List bytes, String filename) async {
  const channel = MethodChannel('com.dustinleblanc.photon.library/gallery');
  try {
    await channel.invokeMethod<void>(method, {
      'bytes': bytes,
      'filename': filename,
    });
    return true;
  } on PlatformException {
    return false;
  } catch (_) {
    return false;
  }
}