//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <face_detection_tflite/face_detection_tflite_plugin.h>
#include <flutter_secure_storage_linux/flutter_secure_storage_linux_plugin.h>
#include <object_detection/object_detection_plugin.h>
#include <url_launcher_linux/url_launcher_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) face_detection_tflite_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FaceDetectionTflitePlugin");
  face_detection_tflite_plugin_register_with_registrar(face_detection_tflite_registrar);
  g_autoptr(FlPluginRegistrar) flutter_secure_storage_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FlutterSecureStorageLinuxPlugin");
  flutter_secure_storage_linux_plugin_register_with_registrar(flutter_secure_storage_linux_registrar);
  g_autoptr(FlPluginRegistrar) object_detection_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ObjectDetectionPlugin");
  object_detection_plugin_register_with_registrar(object_detection_registrar);
  g_autoptr(FlPluginRegistrar) url_launcher_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "UrlLauncherPlugin");
  url_launcher_plugin_register_with_registrar(url_launcher_linux_registrar);
}
