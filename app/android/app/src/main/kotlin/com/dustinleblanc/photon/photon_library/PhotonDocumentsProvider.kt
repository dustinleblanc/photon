package com.dustinleblanc.photon.photon_library

import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.os.ParcelFileDescriptor.AutoCloseOutputStream
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import org.json.JSONObject
import java.io.FileNotFoundException
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Exposes the Photon photos library through the Storage Access Framework, so any
 * Android app's file/photo picker (wallpaper picker, messaging attach, etc.) can
 * browse and import Proton photos -- like Google Photos does.
 *
 * Talks to the photon serve endpoint on 127.0.0.1 (host forwarded via
 * `adb reverse tcp:8787 tcp:8787`).
 */
class PhotonDocumentsProvider : DocumentsProvider() {

    private val executor = Executors.newCachedThreadPool()

    private val rootDocumentId = "library"
    private val base = "http://127.0.0.1:8787/api/v1"

    // linkId -> captureTime seen during listing, so we can render filenames and
    // metadata without an extra round trip.
    private val metaCache = ConcurrentHashMap<String, Long>()

    // ---- Root ---- //

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<String>?): Cursor {
        return MatrixCursor(defaultRootColumns()).apply {
            val row = newRow()
            row.add(Root.COLUMN_ROOT_ID, "photon")
            row.add(Root.COLUMN_ICON, null)
            row.add(Root.COLUMN_TITLE, "Proton Photos")
            row.add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_IS_CHILD or Root.FLAG_SUPPORTS_SEARCH)
            row.add(Root.COLUMN_DOCUMENT_ID, rootDocumentId)
            row.add(Root.COLUMN_MIME_TYPES, "image/*")
            row.add(Root.COLUMN_AVAILABLE_BYTES, null)
        }
    }

    // ---- Document tree ---- //

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor {
        if (documentId == rootDocumentId) {
            return MatrixCursor(defaultDocumentColumns()).apply {
                newRow().also { row ->
                    row.add(Document.COLUMN_DOCUMENT_ID, rootDocumentId)
                    row.add(Document.COLUMN_DISPLAY_NAME, "Proton Photos")
                    row.add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
                    row.add(Document.COLUMN_FLAGS, Root.FLAG_SUPPORTS_IS_CHILD)
                    row.add(Document.COLUMN_SIZE, null)
                    row.add(Document.COLUMN_LAST_MODIFIED, null)
                }
            }
        }
        val ts = metaCache[documentId] ?: 0L
        return MatrixCursor(defaultDocumentColumns()).apply {
            newRow().also { row ->
                row.add(Document.COLUMN_DOCUMENT_ID, documentId)
                row.add(Document.COLUMN_DISPLAY_NAME, filenameFor(documentId, ts))
                row.add(Document.COLUMN_MIME_TYPE, "image/jpeg")
                row.add(Document.COLUMN_FLAGS, Document.FLAG_SUPPORTS_THUMBNAIL)
                row.add(Document.COLUMN_SIZE, null)
                row.add(Document.COLUMN_LAST_MODIFIED, ts * 1000L)
            }
        }
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?,
    ): Cursor {
        val x = defaultDocumentColumns()
        if (parentDocumentId != rootDocumentId) return MatrixCursor(x)

        val page = fetchAssetsPage()
        if (page == null) return MatrixCursor(x)

        return MatrixCursor(x).apply {
            for (row in page) {
                val linkId = row["linkId"] as? String ?: continue
                val captureTime = (row["captureTime"] as? Long) ?: 0L
                metaCache[linkId] = captureTime
                newRow().also { r ->
                    r.add(Document.COLUMN_DOCUMENT_ID, linkId)
                    r.add(Document.COLUMN_DISPLAY_NAME, filenameFor(linkId, captureTime))
                    r.add(Document.COLUMN_MIME_TYPE, "image/jpeg")
                    r.add(Document.COLUMN_FLAGS, Document.FLAG_SUPPORTS_THUMBNAIL)
                    r.add(Document.COLUMN_SIZE, null)
                    r.add(Document.COLUMN_LAST_MODIFIED, captureTime * 1000L)
                }
            }
        }
    }

    override fun getDocumentMetadata(documentId: String): Bundle? {
        if (documentId == rootDocumentId) return null
        val ts = metaCache[documentId] ?: return null
        return Bundle().apply {
            putString(Document.COLUMN_MIME_TYPE, "image/jpeg")
            putLong(Document.COLUMN_LAST_MODIFIED, ts * 1000L)
        }
    }

    override fun querySearchDocuments(
        rootId: String,
        query: String,
        projection: Array<String>?,
    ): Cursor {
        val x = defaultDocumentColumns()
        if (rootId != "photon" || query.isBlank()) return MatrixCursor(x)

        val rows = mutableListOf<Map<String, Any>>()
        var cursor: String? = null
        repeat(8) {
            val next = fetchAssetsPage(cursor)
            if (next.isNullOrEmpty()) return@repeat
            cursor = if (next.size >= 500) next.last()["linkId"] as String else null
            rows.addAll(next)
            if (cursor == null) return@repeat
        }
        val needle = query.lowercase()
        return MatrixCursor(x).apply {
            for (row in rows) {
                val linkId = row["linkId"] as? String ?: continue
                val captureTime = (row["captureTime"] as? Long) ?: 0L
                if (filenameFor(linkId, captureTime).lowercase().contains(needle)) {
                    newRow().also { r ->
                        r.add(Document.COLUMN_DOCUMENT_ID, linkId)
                        r.add(Document.COLUMN_DISPLAY_NAME, filenameFor(linkId, captureTime))
                        r.add(Document.COLUMN_MIME_TYPE, "image/jpeg")
                        r.add(Document.COLUMN_FLAGS, Document.FLAG_SUPPORTS_THUMBNAIL)
                    }
                }
            }
        }
    }

    // ---- Open / thumbnail ---- //

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        require(documentId != rootDocumentId) { "Directory has no content" }
        require(mode == "r") { "Read-only provider" }
        return pipeStream("/assets/$documentId/original")
    }

    override fun openTypedDocument(
        documentId: String,
        mimeTypeFilter: String,
        opts: Bundle?,
        signal: CancellationSignal?,
    ): AssetFileDescriptor {
        if (documentId == rootDocumentId) throw FileNotFoundException(documentId)
        val wantThumbnail = opts?.getBoolean("android.provider.extra.LOAD_THUMBNAIL") == true
        val path = if (wantThumbnail) {
            "/assets/$documentId/preview?size=1600"
        } else {
            "/assets/$documentId/original"
        }
        val pipe = pipeStream(path)
        return AssetFileDescriptor(pipe, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point?,
        signal: CancellationSignal?,
    ): AssetFileDescriptor {
        if (documentId == rootDocumentId) throw FileNotFoundException(documentId)
        val pipe = pipeStream("/assets/$documentId/preview?size=512")
        return AssetFileDescriptor(pipe, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    // ---- API helpers ---- //

    /**
     * Fetches one page of assets; returns a list of [linkId, captureTime] rows.
     * Returns null on error / not authenticated (so the UI shows an empty source).
     */
    private fun fetchAssetsPage(cursor: String? = null): List<Map<String, Any>>? {
        val path = buildString {
            append("/assets?pageSize=500")
            if (cursor != null) append("&cursor=").append(Uri.encode(cursor))
        }
        val conn = open(path) ?: return null
        return try {
            conn.connect()
            if (conn.responseCode != 200) return null
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val arr = JSONObject(body).optJSONArray("assets") ?: return emptyList()
            val out = mutableListOf<Map<String, Any>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out.add(
                    mapOf(
                        "linkId" to o.optString("linkId"),
                        "captureTime" to o.optLong("captureTime"),
                    ),
                )
            }
            out
        } catch (e: IOException) {
            null
        } finally {
            conn.disconnect()
        }
    }

    private fun pipeStream(path: String): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createPipe()
        executor.execute {
            try {
                streamUrl(path, pipe[1])
            } catch (e: IOException) {
                closeQuietly(pipe[1])
            }
        }
        return pipe[0]
    }

    private fun streamUrl(path: String, out: ParcelFileDescriptor) {
        val conn = open(path) ?: throw IOException("no connection")
        AutoCloseOutputStream(out).use { os ->
            try {
                conn.connect()
                if (conn.responseCode != 200) throw IOException("HTTP ${conn.responseCode}")
                conn.inputStream.use { remote -> remote.copyTo(os) }
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun open(path: String): HttpURLConnection? {
        return try {
            URL(buildString { append(base).append(path) }).openConnection() as HttpURLConnection
        } catch (e: IOException) {
            null
        }
    }

    private fun closeQuietly(fd: ParcelFileDescriptor) {
        try {
            fd.close()
        } catch (_: IOException) {
        }
    }

    // ---- Columns ---- //

    private fun defaultRootColumns(): Array<String> = arrayOf(
        Root.COLUMN_ROOT_ID,
        Root.COLUMN_ICON,
        Root.COLUMN_TITLE,
        Root.COLUMN_FLAGS,
        Root.COLUMN_DOCUMENT_ID,
        Root.COLUMN_MIME_TYPES,
        Root.COLUMN_AVAILABLE_BYTES,
    )

    private fun defaultDocumentColumns(): Array<String> = arrayOf(
        Document.COLUMN_DOCUMENT_ID,
        Document.COLUMN_DISPLAY_NAME,
        Document.COLUMN_MIME_TYPE,
        Document.COLUMN_FLAGS,
        Document.COLUMN_SIZE,
        Document.COLUMN_LAST_MODIFIED,
    )

    private fun filenameFor(linkId: String, captureTime: Long): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US)
        val stamp = fmt.format(Date(captureTime * 1000L))
        return "photon_$stamp.jpg"
    }

    override fun shutdown() {
        executor.shutdown()
        super.shutdown()
    }
}