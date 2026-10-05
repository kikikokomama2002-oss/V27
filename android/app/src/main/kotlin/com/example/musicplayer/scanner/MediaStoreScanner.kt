package com.example.musicplayer.scanner

import android.content.ContentUris
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Data returned by a volume-specific MediaStore audio query. */
data class TrackDto(
    val id: Long,
    val volume: String,
    val title: String?,
    val artist: String?,
    val album: String?,
    val duration: Long,
    val contentUri: String,
    val relativePath: String?,
    val displayName: String?,
    val dateModified: Long,
    val generationModified: Long? = null,
)

/**
 * Incremental MediaStore scanner. Every row retains the exact volume used
 * for the query and its volume-specific content URI, so MediaStore IDs are
 * never treated as globally unique.
 */
object MediaStoreScanner {

    // Keep the persisted identity stable across Android versions without
    // touching Q-only MediaStore volume APIs on legacy devices. The literal
    // is the canonical name used by the app for primary external storage.
    private const val PRIMARY_VOLUME = "external_primary"

    fun externalVolumes(context: Context): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return listOf(PRIMARY_VOLUME)
        }
        val volumes = MediaStore.getExternalVolumeNames(context).toList()
        check(volumes.isNotEmpty()) { "MediaStore returned no external volumes" }
        return volumes
    }

    private fun audioCollection(volume: String) =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(volume)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

    suspend fun scanAudioIdentities(
        context: Context,
        volume: String,
        ids: List<Long>,
    ): List<TrackDto> = withContext(Dispatchers.IO) {
        require(ids.isNotEmpty() && ids.size <= 500) { "ids must contain 1..500 items" }
        require(ids.all { it > 0 }) { "MediaStore ids must be positive" }
        val collection = audioCollection(volume)
        val projection = buildList {
            add(MediaStore.Audio.Media._ID)
            add(MediaStore.Audio.Media.TITLE)
            add(MediaStore.Audio.Media.ARTIST)
            add(MediaStore.Audio.Media.ALBUM)
            add(MediaStore.Audio.Media.DURATION)
            add(MediaStore.Audio.Media.DISPLAY_NAME)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) add(MediaStore.Audio.Media.RELATIVE_PATH)
            add(MediaStore.Audio.Media.DATE_MODIFIED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) add(MediaStore.Audio.Media.GENERATION_MODIFIED)
        }.toTypedArray()
        val uniqueIds = ids.distinct()
        val selection = "${MediaStore.Audio.Media.IS_MUSIC}=1 AND ${MediaStore.Audio.Media._ID} IN (${uniqueIds.joinToString(",") { "?" }})"
        val args = uniqueIds.map(Long::toString).toTypedArray()
        val cursor = context.contentResolver.query(collection, projection, selection, args, null)
            ?: throw IllegalStateException("MediaStore identity query failed for volume $volume")
        cursor.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val displayNameCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val relativePathCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) c.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH) else -1
            val modifiedCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_MODIFIED)
            val generationCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) c.getColumnIndex(MediaStore.Audio.Media.GENERATION_MODIFIED) else -1
            buildList {
                while (c.moveToNext()) {
                    val id = c.getLong(idCol)
                    add(TrackDto(
                        id = id,
                        volume = volume,
                        title = c.getString(titleCol),
                        artist = c.getString(artistCol),
                        album = c.getString(albumCol),
                        duration = c.getLong(durationCol),
                        contentUri = ContentUris.withAppendedId(collection, id).toString(),
                        relativePath = if (relativePathCol >= 0) c.getString(relativePathCol) else null,
                        displayName = c.getString(displayNameCol),
                        dateModified = c.getLong(modifiedCol),
                        generationModified = if (generationCol >= 0) c.getLong(generationCol) else null,
                    ))
                }
            }
        }
    }

    suspend fun scanAudioPage(
        context: Context,
        volume: String,
        sinceTimestampSeconds: Long = 0L,
        untilTimestampSeconds: Long = Long.MAX_VALUE,
        cursorDateModifiedSeconds: Long = Long.MAX_VALUE,
        cursorMediaStoreId: Long = Long.MAX_VALUE,
        sinceGeneration: Long = -1L,
        untilGeneration: Long = -1L,
        cursorGeneration: Long = Long.MAX_VALUE,
        limit: Int = 500,
    ): List<TrackDto> = withContext(Dispatchers.IO) {
        require(limit in 1..1000) { "limit must be between 1 and 1000" }

        val collection = audioCollection(volume)
        val projection = buildList {
            add(MediaStore.Audio.Media._ID)
            add(MediaStore.Audio.Media.TITLE)
            add(MediaStore.Audio.Media.ARTIST)
            add(MediaStore.Audio.Media.ALBUM)
            add(MediaStore.Audio.Media.DURATION)
            add(MediaStore.Audio.Media.DISPLAY_NAME)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.Audio.Media.RELATIVE_PATH)
            }
            add(MediaStore.Audio.Media.DATE_MODIFIED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                add(MediaStore.Audio.Media.GENERATION_MODIFIED)
            }
        }.toTypedArray()

        val generationMode = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            sinceGeneration >= 0L && untilGeneration >= sinceGeneration
        val selection: String
        val args: Array<String>
        val sortOrder: String
        if (generationMode) {
            selection = "${MediaStore.Audio.Media.IS_MUSIC}=1" +
                " AND ${MediaStore.Audio.Media.GENERATION_MODIFIED} > ?" +
                " AND ${MediaStore.Audio.Media.GENERATION_MODIFIED} <= ?" +
                " AND (" +
                "${MediaStore.Audio.Media.GENERATION_MODIFIED} < ?" +
                " OR (${MediaStore.Audio.Media.GENERATION_MODIFIED} = ? AND ${MediaStore.Audio.Media._ID} < ?)" +
                ")"
            args = arrayOf(
                sinceGeneration.toString(), untilGeneration.toString(),
                cursorGeneration.toString(), cursorGeneration.toString(), cursorMediaStoreId.toString()
            )
            sortOrder = "${MediaStore.Audio.Media.GENERATION_MODIFIED} DESC, ${MediaStore.Audio.Media._ID} DESC LIMIT $limit"
        } else {
            selection = "${MediaStore.Audio.Media.IS_MUSIC}=1" +
                " AND ${MediaStore.Audio.Media.DATE_MODIFIED} > ?" +
                " AND ${MediaStore.Audio.Media.DATE_MODIFIED} <= ?" +
                " AND (" +
                "${MediaStore.Audio.Media.DATE_MODIFIED} < ?" +
                " OR (${MediaStore.Audio.Media.DATE_MODIFIED} = ? AND ${MediaStore.Audio.Media._ID} < ?)" +
                ")"
            args = arrayOf(
                sinceTimestampSeconds.toString(), untilTimestampSeconds.toString(),
                cursorDateModifiedSeconds.toString(), cursorDateModifiedSeconds.toString(), cursorMediaStoreId.toString()
            )
            sortOrder = "${MediaStore.Audio.Media.DATE_MODIFIED} DESC, ${MediaStore.Audio.Media._ID} DESC LIMIT $limit"
        }

        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val queryArgs = android.os.Bundle().apply {
                putStringArray(
                    android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS,
                    if (generationMode) arrayOf(MediaStore.Audio.Media.GENERATION_MODIFIED, MediaStore.Audio.Media._ID)
                    else arrayOf(MediaStore.Audio.Media.DATE_MODIFIED, MediaStore.Audio.Media._ID)
                )
                putInt(
                    android.content.ContentResolver.QUERY_ARG_SORT_DIRECTION,
                    android.content.ContentResolver.QUERY_SORT_DIRECTION_DESCENDING
                )
                putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, limit)
                                putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
            }
            context.contentResolver.query(collection, projection, queryArgs, null)
        } else {
            context.contentResolver.query(
                collection,
                projection,
                selection,
                args,
                sortOrder
            )
        } ?: throw IllegalStateException("MediaStore query failed for volume $volume")

        val rows = cursor.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val displayNameCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val relativePathCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                c.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
            } else -1
            val modifiedCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_MODIFIED)
            val generationCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) c.getColumnIndex(MediaStore.Audio.Media.GENERATION_MODIFIED) else -1
            buildList {
                while (c.moveToNext()) {
                    val id = c.getLong(idCol)
                    add(TrackDto(
                        id = id,
                        volume = volume,
                        title = c.getString(titleCol),
                        artist = c.getString(artistCol),
                        album = c.getString(albumCol),
                        duration = c.getLong(durationCol),
                        contentUri = ContentUris.withAppendedId(collection, id).toString(),
                        relativePath = if (relativePathCol >= 0) c.getString(relativePathCol) else null,
                        displayName = c.getString(displayNameCol),
                        dateModified = c.getLong(modifiedCol),
                        generationModified = if (generationCol >= 0) c.getLong(generationCol) else null,
                    ))
                }
            }
        }

        if (rows.isEmpty()) {
            // A transient empty provider page must not be mistaken for a real
            // end-of-range. Re-run the exact predicate as a bounded existence
            // probe; only a genuinely empty probe is considered terminal.
            val probe = context.contentResolver.query(
                collection,
                arrayOf(MediaStore.Audio.Media._ID),
                selection,
                args,
                null,
            ) ?: throw IllegalStateException("MediaStore empty-page verification query failed for volume $volume")
            probe.use { p ->
                if (p.moveToFirst()) {
                    throw IllegalStateException("MediaStore returned a transient empty page for volume $volume")
                }
            }
        }
        rows
    }

    /**
     * Returns the subset of volume+ID identities that still exist. The input
     * is bounded by the caller; each volume is queried separately so an ID
     * on one volume can never validate an ID on another volume.
     */
    /**
     * Returns the subset of volume+ID identities that currently exist.
     * Unlike findExistingMediaStoreIdentities(), this intentionally validates
     * only row existence. It is used by ordinary MediaStore observer hints,
     * where metadata/generation changes are the expected event rather than an
     * identity-corruption condition.
     */
    suspend fun findExistingMediaStoreObserverIdentities(
        context: Context,
        candidates: List<Pair<String, Long>>,
    ): Set<String> = withContext(Dispatchers.IO) {
        if (candidates.isEmpty()) return@withContext emptySet()
        require(candidates.size <= 500) { "too many identity candidates" }
        val normalized = candidates.map { (rawVolume, id) ->
            val volume = rawVolume.trim()
            require(volume.isNotEmpty()) { "invalid volume" }
            require(id > 0) { "id must be positive" }
            volume to id
        }.distinct()
        require(normalized.size == candidates.size) { "duplicate identity candidates" }

        val existing = mutableSetOf<String>()
        normalized.groupBy { it.first }.forEach { (volume, volumeCandidates) ->
            val ids = volumeCandidates.map { it.second }.distinct()
            val placeholders = ids.joinToString(",") { "?" }
            val selection = "${MediaStore.Audio.Media._ID} IN ($placeholders)" +
                " AND ${MediaStore.Audio.Media.IS_MUSIC}=1"
            val cursor = context.contentResolver.query(
                audioCollection(volume),
                arrayOf(MediaStore.Audio.Media._ID),
                selection,
                ids.map(Long::toString).toTypedArray(),
                null,
            ) ?: throw IllegalStateException("MediaStore observer query failed for volume $volume")
            cursor.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                while (c.moveToNext()) {
                    existing.add(identityKey(volume, c.getLong(idCol)))
                }
            }
        }
        existing
    }

    suspend fun findExistingMediaStoreIdentities(
        context: Context,
        candidates: List<Map<String, Any?>>,
    ): Set<String> = withContext(Dispatchers.IO) {
        if (candidates.isEmpty()) return@withContext emptySet()
        require(candidates.size <= 500) { "too many identity candidates" }

        data class Candidate(
            val volume: String,
            val id: Long,
            val dateModified: Long,
            val durationMs: Long,
            val displayName: String,
            val relativePath: String?,
            val title: String,
            val artist: String,
            val album: String,
            val contentUri: String,
            val generationModified: Long?,
        )

        val parsed = candidates.map { item ->
            val volume = (item["volume"] as? String)?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: throw IllegalArgumentException("invalid volume")
            val id = (item["id"] as? Number)?.toLong()
                ?: throw IllegalArgumentException("invalid id")
            require(id > 0) { "id must be positive" }
            val dateModified = (item["dateModified"] as? Number)?.toLong()
                ?: throw IllegalArgumentException("invalid dateModified")
            val durationMs = (item["durationMs"] as? Number)?.toLong()
                ?: throw IllegalArgumentException("invalid durationMs")
            val displayName = item["displayName"] as? String
                ?: throw IllegalArgumentException("invalid displayName")
            val relativePath = item["relativePath"] as? String
            val title = item["title"] as? String ?: throw IllegalArgumentException("invalid title")
            val artist = item["artist"] as? String ?: throw IllegalArgumentException("invalid artist")
            val album = item["album"] as? String ?: throw IllegalArgumentException("invalid album")
            val contentUri = item["contentUri"] as? String
                ?: throw IllegalArgumentException("invalid contentUri")
            val generationModified = (item["generationModified"] as? Number)?.toLong()
            Candidate(
                volume, id, dateModified, durationMs, displayName, relativePath,
                title, artist, album, contentUri, generationModified
            )
        }
        require(parsed.map { "${it.volume}:${it.id}" }.toSet().size == parsed.size) {
            "duplicate identity candidates"
        }

        val candidateVolumes = parsed.map { it.volume }.toSet()
        val initialVolumes = externalVolumes(context).toSet()
        if (!initialVolumes.containsAll(candidateVolumes)) {
            throw IllegalStateException("MediaStore volume set changed during deletion validation")
        }

        fun volumeState(volume: String): Pair<Long, String> {
            val generation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                MediaStore.getGeneration(context, volume)
            } else {
                0L
            }
            val version = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.getVersion(context, volume) ?: ""
            } else {
                "legacy"
            }
            return generation to version
        }

        val initialStates = candidateVolumes.associateWith(::volumeState)
        val existing = mutableSetOf<String>()

        parsed.groupBy { it.volume }.forEach { (volume, volumeCandidates) ->
            val collection = audioCollection(volume)
            val projection = buildList {
                add(MediaStore.Audio.Media._ID)
                add(MediaStore.Audio.Media.DATE_MODIFIED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                add(MediaStore.Audio.Media.GENERATION_MODIFIED)
            }
                add(MediaStore.Audio.Media.DURATION)
                add(MediaStore.Audio.Media.DISPLAY_NAME)
                add(MediaStore.Audio.Media.TITLE)
                add(MediaStore.Audio.Media.ARTIST)
                add(MediaStore.Audio.Media.ALBUM)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    add(MediaStore.Audio.Media.RELATIVE_PATH)
                }
            }.toTypedArray()

            val ids = volumeCandidates.map { it.id }.distinct()
            val placeholders = ids.joinToString(",") { "?" }
            val selection = "${MediaStore.Audio.Media._ID} IN ($placeholders)" +
                " AND ${MediaStore.Audio.Media.IS_MUSIC}=1"
            val args = ids.map(Long::toString).toTypedArray()
            val cursor = context.contentResolver.query(
                collection, projection, selection, args, null
            ) ?: throw IllegalStateException("MediaStore validation query failed for volume $volume")

            cursor.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val dateCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_MODIFIED)
                val durationCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val nameCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
                val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val generationCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    c.getColumnIndex(MediaStore.Audio.Media.GENERATION_MODIFIED)
                } else -1
                val relativeCol = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    c.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
                } else -1

                val byId = volumeCandidates.associateBy { it.id }
                while (c.moveToNext()) {
                    val id = c.getLong(idCol)
                    val expected = byId[id] ?: continue
                    val actualUri = ContentUris.withAppendedId(collection, id).toString()
                    val actualGeneration = if (generationCol >= 0) c.getLong(generationCol) else null
                    val actualRelative = if (relativeCol >= 0) c.getString(relativeCol) else null

                    val matches =
                        c.getLong(dateCol) == expected.dateModified &&
                        c.getLong(durationCol) == expected.durationMs &&
                        (c.getString(nameCol) ?: "") == expected.displayName &&
                        canonicalIdentityText(c.getString(titleCol), "Unknown Title") ==
                            canonicalIdentityText(expected.title, "Unknown Title") &&
                        canonicalIdentityText(c.getString(artistCol), "Unknown Artist") ==
                            canonicalIdentityText(expected.artist, "Unknown Artist") &&
                        canonicalIdentityText(c.getString(albumCol), "Unknown Album") ==
                            canonicalIdentityText(expected.album, "Unknown Album") &&
                        actualRelative == expected.relativePath &&
                        actualUri == expected.contentUri &&
                        (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                            actualGeneration == expected.generationModified)

                    if (!matches) {
                        // An existing row with the same volume+ID but different
                        // stable metadata is an ID-reuse/version race. Fail
                        // closed rather than classifying it as a deletion.
                        throw IllegalStateException(
                            "MediaStore identity changed during deletion validation: $volume:$id"
                        )
                    }
                    existing.add(identityKey(volume, id))
                }
            }
        }

        val finalVolumes = externalVolumes(context).toSet()
        if (finalVolumes != initialVolumes ||
            !finalVolumes.containsAll(candidateVolumes)) {
            throw IllegalStateException("MediaStore volume set changed during deletion validation")
        }
        val finalStates = candidateVolumes.associateWith(::volumeState)
        if (finalStates != initialStates) {
            throw IllegalStateException("MediaStore generation/version changed during deletion validation")
        }
        existing
    }

    fun TrackDto.toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "volume" to volume,
        "title" to title,
        "artist" to artist,
        "album" to album,
        "duration" to duration,
        "contentUri" to contentUri,
        "relativePath" to relativePath,
        "displayName" to displayName,
        "dateModified" to dateModified,
        "generationModified" to generationModified,
    )

    fun identityKey(volume: String, id: Long): String = "$volume:$id"

    private fun canonicalIdentityText(value: String?, fallback: String): String =
        value?.trim()?.takeIf { it.isNotEmpty() } ?: fallback

    fun identityKeyFromContentUri(id: Long, contentUri: String): String {
        require(id > 0) { "MediaStore id must be positive" }
        val uri = android.net.Uri.parse(contentUri)
        require(uri.scheme == "content" && uri.authority == "media") {
            "MediaStore content URI is invalid"
        }
        val volume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.getVolumeName(uri)
        } else {
            PRIMARY_VOLUME
        }
        val canonicalVolume = if (volume == "external") PRIMARY_VOLUME else volume
        require(canonicalVolume.isNotBlank()) { "MediaStore volume is invalid" }
        return "$canonicalVolume:$id"
    }
}
