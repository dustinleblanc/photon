import 'dart:io';

import 'package:flutter/services.dart';

/// Saves image bytes into the Android MediaStore (Pictures/Photon Library).
///
/// Requires the Kotlin gallery MethodChannel in MainActivity. On non-Android
/// platforms this returns false without doing anything.
Future<bool> saveImageToGallery(Uint8List bytes, String filename) async {
  if (!Platform.isAndroid) return false;
  const channel = MethodChannel('com.dustinleblanc.photon.library/gallery');
  try {
    await channel.invokeMethod<void>('saveToGallery', {
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