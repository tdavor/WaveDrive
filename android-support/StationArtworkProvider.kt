package com.wavedrive.wavedrive

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/** Exposes only WaveDrive's own cached PNG artwork, read-only. */
class StationArtworkProvider : ContentProvider() {
    override fun onCreate() = true

    private fun artwork(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException()
        val parts = uri.pathSegments
        if (parts.size != 1 || !parts[0].matches(Regex("[A-Za-z0-9_-]{1,180}")))
            throw FileNotFoundException()
        val station = File(File(ctx.filesDir, "car_artwork"), parts[0] + ".png")
        if (station.isFile && station.length() > 0) return station
        val fallback = File(ctx.cacheDir, "wavedrive_car_logo.png")
        synchronized(this) {
            if (!fallback.isFile || fallback.length() == 0L) {
                ctx.resources.openRawResource(R.drawable.wavedrive_launch_logo).use { input ->
                    fallback.outputStream().use { output -> input.copyTo(output) }
                }
            }
        }
        return fallback
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read only")
        return ParcelFileDescriptor.open(artwork(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun getType(uri: Uri) = "image/png"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = artwork(uri)
        val columns = projection?.toList() ?: listOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns.toTypedArray()).apply {
            val row: Array<Any?> = Array(columns.size) { index ->
                when (columns[index]) {
                    OpenableColumns.DISPLAY_NAME -> "station.png"
                    OpenableColumns.SIZE -> file.length()
                    else -> null
                }
            }
            addRow(row)
        }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}
