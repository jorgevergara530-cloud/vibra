package com.vibra.vibra

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Extiende AudioServiceActivity (requerido por just_audio_background) y expone
 * el canal "vibra/local_music" para leer la música guardada en el teléfono
 * mediante MediaStore, sin dependencias de terceros.
 */
class MainActivity : AudioServiceActivity() {

    private val io = Executors.newSingleThreadExecutor()
    private var pendingPermission: MethodChannel.Result? = null

    private val audioPermission: String
        get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun hasPermission() =
        checkSelfPermission(audioPermission) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasPermission())

                    "requestPermission" -> when {
                        hasPermission() -> result.success(true)
                        pendingPermission != null ->
                            result.error("BUSY", "Solicitud de permiso en curso", null)
                        else -> {
                            pendingPermission = result
                            requestPermissions(arrayOf(audioPermission), REQ_AUDIO)
                        }
                    }

                    "openSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }

                    "getSongs" -> io.execute {
                        try {
                            val songs = querySongs()
                            runOnUiThread { result.success(songs) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("QUERY", e.message, null) }
                        }
                    }

                    "getArt" -> {
                        val id = call.argument<String>("id")?.toLongOrNull()
                        if (id == null) {
                            result.success(null)
                        } else io.execute {
                            val bytes = loadArt(id)
                            runOnUiThread { result.success(bytes) }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_AUDIO) {
            pendingPermission?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            pendingPermission = null
        }
    }

    private fun querySongs(): List<Map<String, Any?>> {
        val base = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
        )
        // Solo música (no notas de voz ni tonos) de al menos 20 segundos.
        val selection =
            "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= 20000"
        val out = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            base, projection, selection, null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC"
        )?.use { c ->
            val iId = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val iTitle = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val iArtist = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val iAlbum = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
            val iDur = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            while (c.moveToNext()) {
                val id = c.getLong(iId)
                val albumId = c.getLong(iAlbum)
                val songUri = ContentUris.withAppendedId(base, id)
                val artist = c.getString(iArtist)
                // Carátula para la notificación: en Android 10+ el propio URI
                // de la canción (miniatura incrustada); antes, el albumart.
                val artUri = if (Build.VERSION.SDK_INT >= 29) songUri
                else ContentUris.withAppendedId(ALBUM_ART, albumId)
                out.add(
                    mapOf(
                        "id" to id.toString(),
                        "title" to (c.getString(iTitle) ?: "Sin título"),
                        "artist" to (if (artist.isNullOrBlank() || artist == "<unknown>")
                            "Artista desconocido" else artist),
                        "duration" to c.getLong(iDur),
                        "uri" to songUri.toString(),
                        "art" to artUri.toString(),
                        "albumId" to albumId.toString(),
                    )
                )
            }
        }
        return out
    }

    private fun loadArt(id: Long): ByteArray? = try {
        val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= 29) {
            contentResolver.loadThumbnail(
                ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id),
                Size(ART_PX, ART_PX), null
            )
        } else {
            albumIdOf(id)?.let { albumId ->
                contentResolver.openInputStream(ContentUris.withAppendedId(ALBUM_ART, albumId))
                    ?.use { BitmapFactory.decodeStream(it) }
            }
        }
        bmp?.let {
            val scaled = if (it.width > ART_PX || it.height > ART_PX)
                Bitmap.createScaledBitmap(it, ART_PX, ART_PX, true) else it
            ByteArrayOutputStream().use { o ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 85, o)
                o.toByteArray()
            }
        }
    } catch (e: Exception) {
        null // la canción no tiene carátula
    }

    private fun albumIdOf(id: Long): Long? = contentResolver.query(
        ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id),
        arrayOf(MediaStore.Audio.Media.ALBUM_ID), null, null, null
    )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }

    companion object {
        private const val CHANNEL = "vibra/local_music"
        private const val REQ_AUDIO = 4201
        private const val ART_PX = 300
        private val ALBUM_ART: Uri = Uri.parse("content://media/external/audio/albumart")
    }
}
