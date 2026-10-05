package com.example.musicplayer.lyrics

import android.content.Context
import android.database.Cursor
import android.provider.DocumentsContract
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.provider.MediaStore
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.concurrent.Future
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.Locale
import java.util.LinkedHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * FIX #5 — sidecar `.lrc` lyrics support under Scoped Storage.
 *
 * Given a track's [relativePath] (MediaStore's `RELATIVE_PATH`, e.g.
 * "Music/MyAlbum/") and [displayName] (e.g. "01 Track.mp3"), looks for
 * a sibling lyrics file in the SAME folder whose name — without
 * extension — matches the track's, case-insensitively, with a `.lrc`
 * extension (also case-insensitive). Matching requires BOTH the same
 * directory AND the same filename stem, so a same-named track in a
 * different folder is never matched.
 *
 * Two strategies, tried in order:
 *
 * 1. [viaMediaStore] — `MediaStore.Files` queried by `RELATIVE_PATH` +
 *    `DISPLAY_NAME`, via `ContentResolver`, never `raw filesystem-path column` /
 *    a raw filesystem path. This works on API 29–32, where
 *    `READ_EXTERNAL_STORAGE`/legacy access still grants MediaStore
 *    visibility into non-audio rows. On API 33+, `READ_MEDIA_AUDIO`
 *    does NOT grant visibility into non-audio MediaStore rows (a
 *    `.lrc` file is plain text, not audio) — this query simply returns
 *    no rows there, which is expected and not an error; the caller
 *    falls through to strategy 2.
 *
 * 2. [viaSaf] — Storage Access Framework fallback for API 33+ (or any
 *    case where strategy 1 found nothing): searches every directory
 *    tree the user has explicitly granted via `ACTION_OPEN_DOCUMENT_TREE`
 *    (persisted permissions — see `MainActivity.requestLyricsFolderAccess`)
 *    for a subdirectory matching [relativePath] and a child file
 *    matching the sidecar name. This is the ONLY correct way to reach
 *    an arbitrary non-audio file on API 33+ without a broad
 *    "manage all files" permission this app deliberately doesn't
 *    request. On API 33+, if no usable tree covers the track, the resolver
 *    throws [AccessUnavailableException] rather than returning null; null
 *    is reserved for an authoritative completed search with no matching
 *    sidecar.
 */
object SidecarLyricsResolver {

    class AdmissionException : IllegalStateException("LYRICS_PROVIDER_BUSY")
    class ResourceException(message: String, cause: Throwable? = null) : IllegalStateException(message, cause)
    class ProviderException(message: String, cause: Throwable? = null) : IllegalStateException(message, cause)
    class AccessUnavailableException(
        message: String = "SAF folder access is unavailable for this track",
        cause: Throwable? = null,
    ) : IllegalStateException(message, cause)

    // ContentResolver/SAF providers are external blocking implementations.
    // Never execute them directly on Dispatchers.IO: coroutine cancellation
    // cannot reliably interrupt a provider stuck inside query()/openInputStream().
    // Provider calls are external blocking operations. Each logical request
    // owns its executor so cancelling/quarantining a stuck provider can never
    // interrupt an unrelated sibling request. A semaphore keeps normal
    // provider concurrency bounded to four active calls.
    private const val PROVIDER_WORKERS = 4
    // A timed-out provider is quarantined independently of active capacity.
    // Quarantined workers are bounded so a broken provider cannot consume the
    // entire lifetime of the process's admission capacity.
    private const val PROVIDER_QUARANTINE_MAX = 4

    // Bounded short-lived cache for SAF child lookups. The cache stores only
    // lightweight URI references (including negative misses), never DocumentFile
    // objects or file contents. It is intentionally small and TTL-bound because
    // SAF providers can rename/delete children independently of this process.
    private const val SAF_CHILD_CACHE_MAX_ENTRIES = 512
    private const val SAF_CHILD_CACHE_TTL_MS = 30_000L

    private data class SafChildCacheEntry(
        val uri: Uri?,
        val expiresAtMs: Long,
    )

    private val safCacheLock = Any()
    private val safChildCache = LinkedHashMap<String, SafChildCacheEntry>(
        SAF_CHILD_CACHE_MAX_ENTRIES, 0.75f, true
    )

    private fun cacheSafUri(cacheKey: String, uri: Uri?) {
        val now = System.currentTimeMillis()
        synchronized(safCacheLock) {
            safChildCache[cacheKey] = SafChildCacheEntry(uri, now + SAF_CHILD_CACHE_TTL_MS)
            val iterator = safChildCache.entries.iterator()
            while (safChildCache.size > SAF_CHILD_CACHE_MAX_ENTRIES && iterator.hasNext()) {
                iterator.next()
                iterator.remove()
            }
        }
    }

    private fun invalidateSafUri(cacheKey: String) {
        synchronized(safCacheLock) { safChildCache.remove(cacheKey) }
    }
    private val threadIds = AtomicInteger(0)
    private val providerPermits = Semaphore(PROVIDER_WORKERS, true)
    private val quarantinePermits = Semaphore(PROVIDER_QUARANTINE_MAX, true)
    private val timeoutExecutor = ScheduledThreadPoolExecutor(1) { runnable ->
        Thread(runnable, "lyrics-timeout").apply { isDaemon = true }
    }

    private fun newProviderExecutor(): ThreadPoolExecutor = ThreadPoolExecutor(
        0, 1, 30L, TimeUnit.SECONDS, SynchronousQueue(),
        { runnable -> Thread(runnable, "lyrics-provider-${threadIds.incrementAndGet()}").apply { isDaemon = true } },
    )

    private fun watchTermination(
        executor: ThreadPoolExecutor,
        releasePermit: () -> Unit,
        releaseQuarantine: Boolean,
    ) {
        Thread({
            try {
                executor.awaitTermination(Long.MAX_VALUE, TimeUnit.NANOSECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } finally {
                if (releaseQuarantine) quarantinePermits.release()
                releasePermit()
            }
        }, "lyrics-provider-quarantine-${threadIds.incrementAndGet()}").apply {
            isDaemon = true
            start()
        }
    }

    private suspend fun <T> runProviderWithTimeout(timeoutMs: Long, block: (CancellationSignal) -> T): T? =
        suspendCancellableCoroutine { continuation ->
            // If the bounded quarantine is saturated, do not create another
            // permanently stuck provider worker. Fail closed until one of the
            // quarantined workers actually terminates and returns its slot.
            if (quarantinePermits.availablePermits() == 0) {
                continuation.resumeWithException(AdmissionException())
                return@suspendCancellableCoroutine
            }
            if (!providerPermits.tryAcquire()) {
                continuation.resumeWithException(AdmissionException())
                return@suspendCancellableCoroutine
            }

            val timeoutRef = java.util.concurrent.atomic.AtomicReference<java.util.concurrent.ScheduledFuture<*>?>(null)
            val workerRef = java.util.concurrent.atomic.AtomicReference<Future<*>?>(null)
            val cancellationSignal = CancellationSignal()
            val executor = newProviderExecutor()
            val permitReleased = java.util.concurrent.atomic.AtomicBoolean(false)
            val releasePermit = {
                if (permitReleased.compareAndSet(false, true)) providerPermits.release()
            }
            val shutdownAndWatch = {
                executor.shutdownNow()
                // A stuck executor is quarantined, not allowed to hold an
                // active permit forever. The quarantine itself is bounded.
                val quarantined = quarantinePermits.tryAcquire()
                watchTermination(
                    executor,
                    if (quarantined) ({}) else releasePermit,
                    quarantined,
                )
                // Once quarantined, the active slot is immediately reusable.
                // The quarantine slot remains occupied until the worker dies.
                if (quarantined) releasePermit()
            }

            val timeoutTask = timeoutExecutor.schedule({
                cancellationSignal.cancel()
                val worker = workerRef.get()
                val wasActive = worker != null && !worker.isDone
                worker?.cancel(true)
                shutdownAndWatch()
                if (continuation.isActive && wasActive) {
                    continuation.resumeWithException(
                        java.util.concurrent.TimeoutException("Provider operation timed out")
                    )
                } else if (continuation.isActive) {
                    continuation.resume(null)
                }
            }, timeoutMs, TimeUnit.MILLISECONDS)
            timeoutRef.set(timeoutTask)

            try {
                val worker = executor.submit {
                    try {
                        val value = block(cancellationSignal)
                        timeoutRef.get()?.cancel(false)
                        if (continuation.isActive) continuation.resume(value)
                    } catch (t: Throwable) {
                        timeoutRef.get()?.cancel(false)
                        if (continuation.isActive) continuation.resumeWithException(t)
                    } finally {
                        executor.shutdown()
                    }
                }
                workerRef.set(worker)
                watchTermination(executor, releasePermit, false)
                if (!continuation.isActive) {
                    cancellationSignal.cancel()
                    worker.cancel(true)
                    shutdownAndWatch()
                }
            } catch (t: Throwable) {
                timeoutRef.get()?.cancel(false)
                shutdownAndWatch()
                if (continuation.isActive) continuation.resumeWithException(t)
            }

            continuation.invokeOnCancellation {
                timeoutRef.get()?.cancel(false)
                cancellationSignal.cancel()
                workerRef.get()?.cancel(true)
                shutdownAndWatch()
            }
        }

    suspend fun find(
        context: Context,
        mediaStoreVolume: String?,
        relativePath: String?,
        displayName: String?
    ): String? {
        // A sidecar match is only safe when MediaStore gave us the track's
        // directory identity. Never fall back to a filename-only search when
        // RELATIVE_PATH is unavailable (notably on older Android versions).
        val safeRelativePath = validateRelativePath(relativePath)
        val safeVolume = resolveTrackVolume(context, mediaStoreVolume)
        val stem = stemOf(displayName) ?: return null
        var mediaStoreFailure: Throwable? = null
        try {
            runProviderWithTimeout(5_000L) { signal ->
                viaMediaStore(context, safeVolume, safeRelativePath, stem, signal)
            }?.let { return it }
        } catch (_: AdmissionException) {
            throw AdmissionException()
        } catch (e: java.util.concurrent.TimeoutException) {
            // MediaStore is only strategy 1. SAF is still attempted, but if
            // SAF cannot produce an authoritative answer the timeout must be
            // surfaced rather than cached as a genuine no-lyrics result.
            mediaStoreFailure = e
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // The quarantine executor is deliberately bounded. A rejected
            // provider worker is transient resource pressure; do not convert
            // it into a negative lyrics result.
            throw AdmissionException()
        } catch (e: Exception) {
            // A failed MediaStore strategy is transient provider failure, not
            // evidence that the sidecar is absent. SAF may still succeed.
            mediaStoreFailure = e
        }
        try {
            runProviderWithTimeout(5_000L) { signal ->
                viaSaf(context, safeVolume, safeRelativePath, stem, signal)
            }?.let { return it }
        } catch (_: AdmissionException) {
            throw AdmissionException()
        } catch (e: AccessUnavailableException) {
            throw e
        } catch (e: java.util.concurrent.TimeoutException) {
            throw ProviderException("SAF provider timed out", e)
        }
        mediaStoreFailure?.let { throw ProviderException("MediaStore provider lookup failed", it) }
        return null
    }

    // -----------------------------------------------------------------
    // FIX #saf-folder-resolution (hasLyricsFolderAccess): the previous
    // check only tested whether `persistedUriPermissions` was
    // non-empty — but a listed permission can be stale (revoked from
    // Settings, the SAF provider died, the tree was deleted/moved)
    // while still appearing in that list. This actually resolves each
    // permission to a `DocumentFile` and confirms it's a real,
    // currently-readable directory before reporting access, exactly
    // like `viaSaf`'s own per-tree try/catch below.
    // -----------------------------------------------------------------
    suspend fun hasUsableFolderAccess(
        context: Context,
        mediaStoreVolume: String? = null,
        relativePath: String? = null,
        trackAware: Boolean = false,
    ): Boolean = runProviderWithTimeout<Boolean>(5_000L) { _ ->
        val trackVolume = normalizeVolume(mediaStoreVolume)
        val targetPath = relativePath?.trim('/')?.trim()?.takeIf { it.isNotEmpty() }
        if (trackAware && (trackVolume == null || targetPath == null)) return@runProviderWithTimeout false

        context.contentResolver.persistedUriPermissions.any { permission ->
            if (!permission.isReadPermission) return@any false
            try {
                val dir = DocumentFile.fromTreeUri(context, permission.uri)
                    ?: return@any false
                if (!dir.isDirectory || !dir.canRead()) return@any false

                // With no track context this remains the original generic
                // "does any usable SAF tree exist?" check. When the caller
                // supplies a Track, however, a permission on another volume
                // (or on an unrelated folder on the same volume) must not be
                // reported as usable access for that track.
                if (trackVolume == null || targetPath == null) return@any true

                val documentId = DocumentsContract.getTreeDocumentId(permission.uri)
                val separator = documentId.indexOf(':')
                if (separator <= 0) return@any false

                val treeVolume = normalizeSafVolume(documentId.substring(0, separator))
                    ?: return@any false
                if (treeVolume != trackVolume) return@any false

                val rootPath = documentId.substring(separator + 1).trim('/')
                rootPath.isEmpty() ||
                    targetPath == rootPath ||
                    targetPath.startsWith("$rootPath/")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                false
            }
        }
    } ?: false

    /**
     * Validates MediaStore RELATIVE_PATH before treating a sidecar lookup as
     * authoritative. A non-empty string is not sufficient: absolute paths,
     * traversal segments, empty path segments, backslashes, and control
     * characters do not describe a safe canonical directory identity.
     *
     * The returned value is a validated slash-free directory identity. SAF
     * uses that representation; viaMediaStore() restores MediaStore's
     * canonical trailing-slash representation before exact equality lookup.
     */
    private fun validateRelativePath(relativePath: String?): String {
        val raw = relativePath?.trim()?.takeIf { it.isNotEmpty() }
            ?: throw AccessUnavailableException(
                "Track relative path is unavailable; sidecar lookup is indeterminate"
            )

        if (raw.startsWith('/') || raw.startsWith('\\') || raw.endsWith('\\') ||
            raw.contains('\\') || raw.any { it.code < 0x20 || it.code == 0x7f }) {
            throw AccessUnavailableException("Track relative path is invalid; sidecar lookup is indeterminate")
        }

        val normalized = raw.trim('/').trim()
        if (normalized.isEmpty()) {
            throw AccessUnavailableException("Track relative path is invalid; sidecar lookup is indeterminate")
        }

        val segments = normalized.split('/')
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) {
            throw AccessUnavailableException("Track relative path is invalid; sidecar lookup is indeterminate")
        }

        return normalized
    }

    private fun stemOf(displayName: String?): String? {
        if (displayName.isNullOrBlank()) return null
        val dot = displayName.lastIndexOf('.')
        return if (dot > 0) displayName.substring(0, dot) else displayName
    }

    // -----------------------------------------------------------------
    // Strategy 1: MediaStore.Files, scoped-storage-compliant (no raw filesystem-path
    // column, no raw path) — works where the OS still grants visibility.
    // -----------------------------------------------------------------
    private fun escapeLike(value: String): String =
        value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    private fun viaMediaStore(context: Context, mediaStoreVolume: String?, relativePath: String, stem: String, cancellationSignal: CancellationSignal): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val volume = resolveTrackVolume(context, mediaStoreVolume)
        val collection = MediaStore.Files.getContentUri(volume)
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME
        )

                // Push the common-case filename restriction into MediaStore. SQLite
        // LIKE is ASCII-case-insensitive on Android's standard provider, so
        // this avoids returning every row in a large directory for normal
        // filenames. We still verify the match in Kotlin because provider
        // collations differ and Kotlin's ignoreCase semantics remain the
        // final correctness authority.
        //
        // A successful empty filtered query is authoritative. We deliberately
        // do not enumerate the whole directory as a compatibility fallback.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val expectedName = "$stem.lrc"
        // MediaStore stores RELATIVE_PATH as a directory path with a terminal
        // slash (for example "Music/MyAlbum/"). validateRelativePath() keeps
        // the slash-free identity needed by SAF, so restore the provider's
        // canonical representation before the exact MediaStore query.
        val mediaStoreRelativePath = "${relativePath.trimEnd('/')}/"
        val selection =
            "${MediaStore.Files.FileColumns.RELATIVE_PATH}=? AND " +
                "${MediaStore.Files.FileColumns.DISPLAY_NAME} LIKE ? ESCAPE '\\'"
        val args = arrayOf(mediaStoreRelativePath, escapeLike(expectedName))


        var cursor: Cursor? = null
        return try {
            cursor = context.contentResolver.query(collection, projection, selection, args, null, cancellationSignal)
                ?: throw ProviderException("MediaStore lyrics query returned null cursor")
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            var matchedId: Long? = null
            var matchedName: String? = null
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameCol) ?: continue
                val ext = name.substringAfterLast('.', "")
                if (!ext.equals("lrc", ignoreCase = true)) continue
                val candidateStem = stemOf(name) ?: continue
                if (!candidateStem.equals(stem, ignoreCase = true)) continue

                val id = cursor.getLong(idCol)
                if (matchedName == null || isBetterCandidate(name, id, matchedName!!, matchedId!!, stem)) {
                    matchedName = name
                    matchedId = id
                }
            }
            // A successful filtered query with no candidate is an authoritative miss.
            // Never fall back to a full-directory query for an ordinary empty result.


            val id = matchedId ?: return null
            val fileUri = Uri.withAppendedPath(collection, id.toString())
            val input = context.contentResolver.openInputStream(fileUri)
                ?: throw ProviderException("MediaStore lyrics input stream returned null")
            input.use { readAllText(it) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: ResourceException) {
            throw e
        } catch (e: ProviderException) {
            throw e
        } catch (e: Exception) {
            // A provider/query failure is not an authoritative "no lyrics"
            // result. Surface it to find(), which records the failure and
            // still gives the SAF strategy a chance to succeed.
            throw ProviderException("MediaStore lyrics provider failed", e)
        } finally {
            cursor?.close()
        }
    }

    // -----------------------------------------------------------------
    // Strategy 2: Storage Access Framework — only reaches directories
    // the user explicitly granted via requestLyricsFolderAccess().
    // -----------------------------------------------------------------
    private fun findChildByName(
        context: Context,
        treeUri: Uri,
        parentDocumentId: String,
        expectedName: String,
        wantDirectory: Boolean?,
        cancellationSignal: CancellationSignal? = null
    ): DocumentFile? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri, parentDocumentId
        )
        val normalizedExpectedName = expectedName.lowercase(Locale.ROOT)
        val cacheKey = "child|$treeUri|$parentDocumentId|$normalizedExpectedName|$wantDirectory"
        synchronized(safCacheLock) {
            val entry = safChildCache[cacheKey]
            if (entry != null) {
                if (entry.expiresAtMs > System.currentTimeMillis()) {
                    val cachedUri = entry.uri
                    return cachedUri?.let { DocumentFile.fromSingleUri(context, it) }
                }
                safChildCache.remove(cacheKey)
            }
        }
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        // Ask the provider for the exact spelling first. SAF provider selection
        // semantics are not guaranteed to be case-insensitive, so a successful
        // exact query is followed by a compatibility scan when no exact row is
        // returned. The whole resolver call is bounded by its provider timeout.
        val selection = DocumentsContract.Document.COLUMN_DISPLAY_NAME + " = ?"
        val selectionArgs = arrayOf(expectedName)
        var exactMatchFound = false
        try {
            val exactCursor = context.contentResolver.query(
                childrenUri, projection, selection, selectionArgs, null, cancellationSignal
            ) ?: throw ProviderException("SAF exact child query returned null cursor")
            exactCursor.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                if (idCol < 0 || nameCol < 0 || mimeCol < 0) {
                    throw ProviderException("SAF child query omitted required columns")
                }
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameCol) ?: continue
                    if (!name.equals(expectedName, ignoreCase = true)) continue
                    val mime = cursor.getString(mimeCol) ?: continue
                    val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    if (wantDirectory != null && isDirectory != wantDirectory) continue
                    val childId = cursor.getString(idCol) ?: continue
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                    cacheSafUri(cacheKey, childUri)
                    exactMatchFound = true
                    return DocumentFile.fromSingleUri(context, childUri)
                }
            }
        } catch (e: ProviderException) {
            // A null cursor is an explicit provider failure, not a successful
            // empty result. Do not allow it to fall through into a negative
            // cache entry.
            throw e
        } catch (e: Exception) {
            // Fall through to the compatibility walk below. If that fallback
            // also fails, the caller must see a transient provider failure
            // rather than a cached negative lookup.
        }

        // A provider may perform a case-sensitive equality filter, which would
        // miss e.g. "Song.LRC" when the canonical spelling is "song.lrc". In
        // that case (or when the provider rejected the filtered query), perform
        // one compatibility walk and compare names case-insensitively. This is
        // still bounded by the caller's 5-second provider timeout and happens
        // only after the cheap exact lookup produced no match.
        if (!exactMatchFound) {
            try {
                val compatibilityCursor = context.contentResolver.query(
                    childrenUri, projection, null, null, null, cancellationSignal
                ) ?: throw ProviderException("SAF compatibility child query returned null cursor")
                compatibilityCursor.use { cursor ->
                    val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    if (idCol < 0 || nameCol < 0 || mimeCol < 0) {
                        throw ProviderException("SAF child query omitted required columns")
                    }

                    var bestName: String? = null
                    var bestId: String? = null
                    var bestUri: Uri? = null
                    while (cursor.moveToNext()) {
                        val name = cursor.getString(nameCol) ?: continue
                        if (!name.equals(expectedName, ignoreCase = true)) continue
                        val mime = cursor.getString(mimeCol) ?: continue
                        val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
                        if (wantDirectory != null && isDirectory != wantDirectory) continue
                        val childId = cursor.getString(idCol) ?: continue
                        val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                        val candidateExact = name == expectedName
                        val currentExact = bestName == expectedName
                        val candidateBetter = bestName == null ||
                            (candidateExact && !currentExact) ||
                            (candidateExact == currentExact &&
                                (name.lowercase(Locale.ROOT) < bestName!!.lowercase(Locale.ROOT) ||
                                    (name.lowercase(Locale.ROOT) == bestName!!.lowercase(Locale.ROOT) &&
                                        childId < bestId!!)))
                        if (candidateBetter) {
                            bestName = name
                            bestId = childId
                            bestUri = childUri
                        }
                    }
                    val selectedUri = bestUri ?: return@use
                    cacheSafUri(cacheKey, selectedUri)
                    return DocumentFile.fromSingleUri(context, selectedUri)
                }
            } catch (e: Exception) {
                throw ProviderException("SAF child provider query failed", e)
            }
        }
        // An exact-query failure followed by a successful compatibility query
        // is fine; only a completed query with no matching child is a genuine
        // negative result. If the compatibility query was reached because the
        // exact query failed and returned no child, it still provides an
        // authoritative answer when it completes normally.
        cacheSafUri(cacheKey, null)
        return null
    }

    private fun viaSaf(context: Context, mediaStoreVolume: String?, relativePath: String, stem: String, cancellationSignal: CancellationSignal): String? {
        val granted = context.contentResolver.persistedUriPermissions
        val targetPath = relativePath.trim('/').trim()
        if (targetPath.isEmpty()) return null

        // On Android 13+, MediaStore.Files cannot authoritatively observe
        // non-audio `.lrc` rows with READ_MEDIA_AUDIO. SAF is therefore the
        // required visibility mechanism. "No usable grant for this track" is
        // NOT equivalent to "no lyrics"; surfacing a typed access failure
        // prevents the repository from committing lyricsChecked=true.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val trackVolume = normalizeVolume(mediaStoreVolume)
                ?: throw AccessUnavailableException("SAF folder access cannot resolve the track volume")
            var relevantGrant = false
            for (permission in granted) {
                if (!permission.isReadPermission) continue
                try {
                    val documentId = DocumentsContract.getTreeDocumentId(permission.uri)
                    val separator = documentId.indexOf(':')
                    if (separator <= 0) continue
                    val treeVolume = normalizeSafVolume(documentId.substring(0, separator)) ?: continue
                    if (treeVolume != trackVolume) continue
                    val rootPath = documentId.substring(separator + 1).trim('/')
                    if (rootPath.isEmpty() ||
                        targetPath == rootPath ||
                        targetPath.startsWith("$rootPath/")
                    ) {
                        relevantGrant = true
                        break
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // A malformed/stale grant is not usable for this track;
                    // the per-grant provider pass below will classify real
                    // provider failures if it attempts that grant.
                }
            }
            if (!relevantGrant) {
                throw AccessUnavailableException()
            }
        }

        var providerFailure: Exception? = null

        for (permission in granted) {
            if (!permission.isReadPermission) continue
            var failedCacheKey: String? = null

            try {
                val root = DocumentFile.fromTreeUri(context, permission.uri) ?: continue

                val documentId = DocumentsContract.getTreeDocumentId(permission.uri)
                val separator = documentId.indexOf(':')
                if (separator <= 0) continue
                val treeVolume = normalizeSafVolume(documentId.substring(0, separator)) ?: continue
                val trackVolume = normalizeVolume(mediaStoreVolume) ?: continue
                if (treeVolume != trackVolume) continue
                val rootPath = documentId.substring(separator + 1).trim('/')

                val remaining = when {
                    rootPath.isEmpty() -> targetPath.split('/').filter { it.isNotBlank() }
                    targetPath == rootPath -> emptyList()
                    targetPath.startsWith("$rootPath/") -> {
                        targetPath.substring(rootPath.length).trim('/').split('/')
                            .filter { it.isNotBlank() }
                    }
                    else -> continue
                }

                var dir = root
                var matched = true
                for (segment in remaining) {
                    val childDocumentId = DocumentsContract.getDocumentId(dir.uri)
                    val child = findChildByName(
                        context, permission.uri, childDocumentId, segment, true, cancellationSignal
                    )
                    if (child == null) {
                        matched = false
                        break
                    }
                    dir = child
                }
                if (!matched) continue

                val lyricsName = dir.let { parent ->
                    val parentId = DocumentsContract.getDocumentId(parent.uri)
                    // Exact provider-side child lookup avoids materializing the entire
                    // directory for each uncached stem. A successful empty filtered query
                    // is authoritative; only a query failure may use compatibility fallback.
                    val lyricsName = findChildByName(
                        context, permission.uri, DocumentsContract.getDocumentId(dir.uri),
                        "$stem.lrc", false, cancellationSignal
                    )
                    if (lyricsName == null) return@let null
                    lyricsName
                } ?: continue

                failedCacheKey = "child|${permission.uri}|${DocumentsContract.getDocumentId(dir.uri)}|${"$stem.lrc".lowercase(Locale.ROOT)}|false"
                val input = context.contentResolver.openInputStream(lyricsName)
                    ?: throw ProviderException("SAF lyrics input stream returned null")
                input.use { stream ->
                    readAllText(stream)?.let { return it }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: ResourceException) {
                throw e
            } catch (e: Exception) {
                // Covers revoked permissions, deleted files, and dead SAF
                // providers. A failed tree never aborts the search of another
                // valid grant and never causes a cross-directory guess, but
                // remember the transient failure so the final result cannot be
                // persisted as authoritative "no lyrics".
                providerFailure = e
                failedCacheKey?.let { invalidateSafUri(it) }
                continue
            }
        }
        providerFailure?.let { throw ProviderException("SAF provider lookup failed", it) }
        return null
    }

    /**
     * Deterministic conflict policy for multiple case-insensitive matches.
     * Prefer the canonical `<track-stem>.lrc` spelling, then stable lexical
     * filename order, then the provider's stable row/document identifier.
     */
    private fun compareCandidateNames(
        candidateName: String,
        currentName: String,
        stem: String,
    ): Int {
        val canonical = "$stem.lrc"
        val candidateExact = candidateName == canonical
        val currentExact = currentName == canonical
        if (candidateExact != currentExact) return if (candidateExact) -1 else 1

        val candidateFolded = candidateName.lowercase(Locale.ROOT)
        val currentFolded = currentName.lowercase(Locale.ROOT)
        val foldedCompare = candidateFolded.compareTo(currentFolded)
        if (foldedCompare != 0) return foldedCompare

        return candidateName.compareTo(currentName)
    }

    private fun isBetterCandidate(
        candidateName: String,
        candidateId: Long,
        currentName: String,
        currentId: Long,
        stem: String,
    ): Boolean {
        val nameCompare = compareCandidateNames(candidateName, currentName, stem)
        return nameCompare < 0 || (nameCompare == 0 && candidateId < currentId)
    }

    private fun isBetterCandidate(
        candidateName: String,
        candidateId: String,
        currentName: String,
        currentId: String,
        stem: String,
    ): Boolean {
        val nameCompare = compareCandidateNames(candidateName, currentName, stem)
        return nameCompare < 0 || (nameCompare == 0 && candidateId < currentId)
    }

    private const val PRIMARY_VOLUME = "external_primary"

    private fun normalizeVolume(volume: String?): String? {
        val value = volume?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (value.equals("external", ignoreCase = true)) PRIMARY_VOLUME else value
    }

    /**
     * Resolves the track volume against the volumes actually exposed by
     * MediaStore. A syntactically non-empty string is not sufficient: an
     * unknown volume is an indeterminate lookup identity and must never be
     * allowed to collapse into a successful NOT_FOUND result.
     */
    private fun resolveTrackVolume(context: Context, volume: String?): String {
        val normalized = normalizeVolume(volume)
            ?: throw AccessUnavailableException(
                "Track media volume is unavailable or invalid; sidecar lookup is indeterminate"
            )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val knownVolumes = try {
                MediaStore.getExternalVolumeNames(context)
            } catch (e: Exception) {
                throw AccessUnavailableException(
                    "Track media volume cannot be resolved; sidecar lookup is indeterminate",
                    e
                )
            }
            if (normalized !in knownVolumes) {
                throw AccessUnavailableException(
                    "Track media volume is not currently exposed by MediaStore; sidecar lookup is indeterminate"
                )
            }
        } else if (normalized != PRIMARY_VOLUME) {
            // Before Android Q the app's scanner exposes only the legacy
            // external MediaStore collection, which this project persists
            // under the canonical external_primary identity. There is no
            // volume enumeration API here that could prove an arbitrary
            // persisted string is a real MediaStore volume. Reject it
            // instead of allowing SAF to turn an unresolvable identity into
            // a successful NOT_FOUND result.
            throw AccessUnavailableException(
                "Track media volume cannot be resolved on this Android version; sidecar lookup is indeterminate"
            )
        }

        return normalized
    }

    private fun normalizeSafVolume(volume: String): String? {
        val value = volume.trim()
        return if (value.equals("primary", ignoreCase = true) ||
            value.equals("external", ignoreCase = true)) {
            PRIMARY_VOLUME
        } else {
            value
        }
    }

    private const val MAX_LYRICS_BYTES = 1_048_576
    // SAF child-document queries have no portable server-side filename
    // predicate. The lookup is therefore allowed to walk the provider cursor,
    // but the entire operation is enclosed by the 5-second provider timeout
    // in [find], so a pathological provider cannot hang the app indefinitely.

    private fun readAllText(input: java.io.InputStream): String? {
        // Enforce the limit in actual UTF-8 bytes, not decoded UTF-16 chars.
        // A multibyte lyric file could otherwise exceed the advertised byte
        // cap substantially.
        val bytes = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > MAX_LYRICS_BYTES) {
                throw ResourceException("Sidecar lyrics exceed size limit")
            }
            bytes.write(buffer, 0, read)
        }
        val text = String(bytes.toByteArray(), Charsets.UTF_8)
        // FIX #5.4: a UTF-8 BOM (U+FEFF), if present, decodes as a
        // literal leading character rather than being stripped by
        // InputStreamReader — strip it here so callers (both the plain-
        // text display fallback and LrcParser, which otherwise tolerates
        // it fine since its line regex isn't start-anchored) always see
        // clean text either way.
        return text.removePrefix("\uFEFF").trim().ifEmpty { null }
    }
}
