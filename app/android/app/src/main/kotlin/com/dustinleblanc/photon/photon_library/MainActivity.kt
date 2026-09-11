package com.dustinleblanc.photon.photon_library

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val GALLERY_CHANNEL = "com.dustinleblanc.photon.library/gallery"
    private val PERMISSION_REQUEST_CODE = 1001

    private class PendingSave(
        val bytes: ByteArray,
        val filename: String,
        val result: MethodChannel.Result,
    )

    private var pendingSave: PendingSave? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GALLERY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToGallery" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val filename = call.argument<String>("filename")
                        handleSave(bytes, filename, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleSave(
        bytes: ByteArray?,
        filename: String?,
        result: MethodChannel.Result,
    ) {
        if (bytes == null || filename == null) {
            result.error("INVALID_ARGS", "bytes and filename required", null)
            return
        }
        if (!hasPermission()) {
            pendingSave = PendingSave(bytes, filename, result)
            requestPermission()
            return
        }
        writeToGallery(bytes, filename, result)
    }

    private fun hasPermission(): Boolean {
        // On API 29+ inserting our own images into MediaStore needs no
        // permission; only legacy (API < 29) needs WRITE_EXTERNAL_STORAGE.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST_CODE) return

        val pending = pendingSave
        pendingSave = null
        if (pending == null) return

        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            writeToGallery(pending.bytes, pending.filename, pending.result)
        } else {
            pending.result.error("PERMISSION_DENIED", "Storage permission not granted", null)
        }
    }

    private fun writeToGallery(
        bytes: ByteArray,
        filename: String,
        result: MethodChannel.Result,
    ) {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, filename)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/Photon Library",
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: return result.error("INSERT_FAILED", "Could not create MediaStore entry", null)
        try {
            resolver.openOutputStream(uri)?.use { out ->
                out.write(bytes)
            } ?: return result.error("WRITE_FAILED", "Could not open output stream", null)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            }
            result.success(uri.toString())
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            result.error("WRITE_FAILED", e.message, null)
        }
    }
}