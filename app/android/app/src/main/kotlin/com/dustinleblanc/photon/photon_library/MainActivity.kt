package com.dustinleblanc.photon.photon_library

import android.Manifest
import android.app.WallpaperManager
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val GALLERY_CHANNEL = "com.dustinleblanc.photon.library/gallery"
    private val PERMISSION_REQUEST_CODE = 1001
    private val ioExecutor = Executors.newSingleThreadExecutor()

    private class PendingSave(
        val bytes: ByteArray,
        val filename: String,
        val result: MethodChannel.Result,
        val afterSave: ((String) -> Unit)?,
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
                        handleSave(bytes, filename, result, afterSave = null)
                    }
                    "setAsWallpaper" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val filename = call.argument<String>("filename")
                        handleSetAsWallpaper(bytes, filename, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleSave(
        bytes: ByteArray?,
        filename: String?,
        result: MethodChannel.Result,
        afterSave: ((String) -> Unit)?,
    ) {
        if (bytes == null || filename == null) {
            result.error("INVALID_ARGS", "bytes and filename required", null)
            return
        }
        if (!hasPermission()) {
            pendingSave = PendingSave(bytes, filename, result, afterSave)
            requestPermission()
            return
        }
        writeToGallery(bytes, filename, result, afterSave)
    }

    private fun handleSetAsWallpaper(
        bytes: ByteArray?,
        filename: String?,
        result: MethodChannel.Result,
    ) {
        handleSave(bytes, filename, result) { uriString -> launchWallpaper(uriString) }
    }

    private fun launchWallpaper(uriString: String) {
        val intent = Intent(WallpaperManager.ACTION_CROP_AND_SET_WALLPAPER).apply {
            setDataAndType(Uri.parse(uriString), "image/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val targets = packageManager
            .queryIntentActivities(intent, 0)
            .map { it.activityInfo.packageName }
        // Prefer the Pixel wallpaper preview UI, then the cropper; pin the
        // package so Contacts' "set contact photo" (ATTACH_DATA) can't hijack.
        val target = targets.firstOrNull { it == "com.android.wallpaper" }
            ?: targets.firstOrNull { it == "com.android.wallpapercropper" }
            ?: targets.firstOrNull()
        if (target == null) return
        intent.setPackage(target)
        try {
            startActivity(intent)
        } catch (e: Exception) {
            Log.w("PhotonGallery", "set wallpaper failed: ${e.message}")
        }
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
            writeToGallery(pending.bytes, pending.filename, pending.result, pending.afterSave)
        } else {
            pending.result.error("PERMISSION_DENIED", "Storage permission not granted", null)
        }
    }

    private fun writeToGallery(
        bytes: ByteArray,
        filename: String,
        result: MethodChannel.Result,
        afterSave: ((String) -> Unit)? = null,
    ) {
        ioExecutor.execute {
            val outcome = try {
                val upright = toUprightJpeg(bytes)
                Result.success(insertIntoMediaStore(upright, filename))
            } catch (e: Exception) {
                Result.failure(e)
            }
            runOnUiThread {
                outcome.fold(
                    onSuccess = { uri ->
                        afterSave?.invoke(uri)
                        result.success(uri)
                    },
                    onFailure = { e -> result.error("WRITE_FAILED", e.message, null) },
                )
            }
        }
    }

    private fun insertIntoMediaStore(bytes: ByteArray, filename: String): String {
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
            ?: throw IllegalStateException("Could not create MediaStore entry")
        try {
            resolver.openOutputStream(uri)?.use { out -> out.write(bytes) }
                ?: throw IllegalStateException("Could not open output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            }
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }

    // Some viewers (e.g. the wallpaper cropper) ignore EXIF orientation, so a
    // portrait photo from the iPhone shows sideways. Decode, apply the EXIF
    // rotation to the pixels, and re-encode as an upright JPEG so the bytes are
    // self-correct.
    private fun toUprightJpeg(bytes: ByteArray): ByteArray {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (e: Exception) {
            return bytes
        }
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return bytes
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
            else -> return bytes
        }
        val upright = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
        if (upright != bmp) bmp.recycle()
        val out = ByteArrayOutputStream()
        upright.compress(Bitmap.CompressFormat.JPEG, 95, out)
        upright.recycle()
        return out.toByteArray()
    }
}