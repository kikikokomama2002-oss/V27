package com.example.musicplayer.channels

import android.content.Context
import android.database.ContentObserver
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import com.example.musicplayer.lyrics.EmbeddedLyricsReader
import com.example.musicplayer.lyrics.SidecarLyricsResolver
import com.example.musicplayer.playback.EqualizerController
import com.example.musicplayer.playback.PlaybackService
import com.example.musicplayer.playback.PlayerHolder
import com.example.musicplayer.scanner.AlbumArtLoader
import com.example.musicplayer.scanner.MediaStoreScanner
import com.example.musicplayer.scanner.MediaStoreScanner.toMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicBoolean
import java.util.UUID

const val PLAYER_CHANNEL_NAME = "com.example.musicplayer/player"

/**
 * Handles one-off commands and transport controls from Dart:
 * scanLibrary, findExistingMediaStoreIds (bounded ID batches), setQueueContext, play, pause, seekTo,
 * skipNext, skipPrevious. Delegates all playback state to the shared
 * [PlayerHolder] singleton, which is also used by the foreground
 * [PlaybackService]. Every PlayerHolder call here passes [context], so
 * the underlying ExoPlayer is created lazily and safely no matter which
 * entry point (this channel or the service) is hit first.
 *
 * @param channel FIX #2: the same channel this class handles
 *   incoming calls for, also used to make the reverse call
 *   (`requestQueuePage`) — see `PlayerHolder.ensureQueueController` /
 *   `QueuePageProvider`. Passed in rather than constructed here so
 *   there's exactly one `MethodChannel` instance for this channel name,
 *   shared in both directions.
 * @param launchLyricsFolderPicker FIX #5: launches the SAF
 *   ACTION_OPEN_DOCUMENT_TREE picker (must run from an Activity — see
 *   MainActivity) and resolves the supplied [MethodChannel.Result] with
 *   `true`/`false` once the user picks a folder or cancels.
 */
class PlayerChannel(
    private val context: Context,
    private val channel: MethodChannel,
    private val launchLyricsFolderPicker: (MethodChannel.Result) -> Unit
) : MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mediaStoreObserverHandler = Handler(Looper.getMainLooper())
    @Volatile private var disposed = false

    /**
     * MethodChannel has no automatic cancellation propagation when this
     * engine is torn down. Every asynchronous Result is therefore tracked so
     * dispose() can complete it exactly once instead of leaving Dart's
     * invokeMethod() Future permanently pending.
     */
    private val pendingResults = ConcurrentHashMap.newKeySet<TrackedResult>()
    // Scoped to this Flutter engine/channel instance; AlbumArtLoader itself is
    // process-wide, so Dart-local ids must never collide across engine recreation.
    private val albumArtConsumerEpoch = UUID.randomUUID().toString()

    private inner class TrackedResult(
        private val delegate: MethodChannel.Result
    ) : MethodChannel.Result {
        private val completed = AtomicBoolean(false)

        fun cancelForDispose() {
            if (completed.compareAndSet(false, true)) {
                delegate.error("ENGINE_DISPOSED", "Flutter engine was disposed while the operation was pending", null)
            }
        }

        private fun finish(action: () -> Unit) {
            if (completed.compareAndSet(false, true)) {
                pendingResults.remove(this)
                action()
            }
        }

        override fun success(result: Any?) = finish { delegate.success(result) }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
            finish { delegate.error(errorCode, errorMessage, errorDetails) }
        override fun notImplemented() = finish { delegate.notImplemented() }
    }

    private fun trackResult(result: MethodChannel.Result): TrackedResult {
        val tracked = TrackedResult(result)
        if (disposed) {
            tracked.cancelForDispose()
        } else {
            pendingResults.add(tracked)
            // Close the small dispose/add race: if teardown won after the
            // initial check, remove the newly-added result immediately.
            if (disposed && pendingResults.remove(tracked)) {
                tracked.cancelForDispose()
            }
        }
        return tracked
    }
    @Volatile private var currentLibraryGeneration = 0L
    private const val MAX_PENDING_MEDIASTORE_IDENTITIES = 1024
    private val pendingMediaStoreIdentities = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var pendingMediaStoreUnknown = false
    private val mediaStoreObserverRunnable = Runnable {
        if (disposed) return@Runnable
        val identities = synchronized(pendingMediaStoreIdentities) {
            pendingMediaStoreIdentities.toList().also { pendingMediaStoreIdentities.clear() }
        }
        val unknown = pendingMediaStoreUnknown
        pendingMediaStoreUnknown = false
        channel.invokeMethod(
            "mediaStoreChanged",
            mapOf("identities" to identities, "unknown" to unknown),
        )
    }
    private val registeredObserverUris = mutableSetOf<Uri>()
    private var activeMediaStoreObserver: ContentObserver? = null
    @Volatile private var deletionObservationCoverageComplete = false
    // Sticky until Dart completes a stable deletion reconciliation and asks
    // native to commit the boundary. This closes the race where an observer
    // fails after a previously-valid baseline was written: recovery remains
    // required even if the observer later succeeds again.
    @Volatile private var deletionObservationNeedsReconciliation = true

    private companion object {
        const val OBSERVER_DISCOVERY_RETRY_DELAY_MS = 5_000L
    }

    /**
     * Observer readiness is part of the deletion-correctness state machine.
     * Any failed/incomplete observer refresh invalidates the observation
     * boundary immediately. The flag is sticky until a subsequent stable
     * reconciliation explicitly commits a new boundary.
     */
    private fun invalidateDeletionObservationBoundary() {
        deletionObservationCoverageComplete = false
        deletionObservationNeedsReconciliation = true
    }

    private fun commitDeletionObservationBaseline(epoch: String): Boolean {
        if (epoch.isBlank() || disposed || !deletionObservationCoverageComplete ||
            activeMediaStoreObserver == null || registeredObserverUris.isEmpty() ||
            deletionObservationNeedsReconciliation) {
            return false
        }
        // The MethodChannel handler and observer-refresh registration both run
        // on the main looper, so this check and state transition cannot be
        // interleaved with a concurrent refresh. Dart persists the same epoch
        // only after this native commit succeeds.
        deletionObservationNeedsReconciliation = false
        return true
    }

    private fun observerNeedsDeletionReconciliation(): Boolean =
        disposed || !deletionObservationCoverageComplete ||
            activeMediaStoreObserver == null || registeredObserverUris.isEmpty() ||
            deletionObservationNeedsReconciliation

    private val storageLifecycleGenerations = ConcurrentHashMap<String, Long>()
    private val storageLifecycleStates = ConcurrentHashMap<String, String>()
    private val storageLifecycleEpoch = AtomicLong(0L)

    private fun recordStorageState(volume: String?, state: String?) {
        if (volume.isNullOrBlank() || state.isNullOrBlank()) return
        val previous = storageLifecycleStates.put(volume, state)
        val isUnavailable = state == Environment.MEDIA_REMOVED ||
            state == Environment.MEDIA_UNMOUNTED ||
            state == Environment.MEDIA_BAD_REMOVAL ||
            state == Environment.MEDIA_UNMOUNTABLE ||
            state == Environment.MEDIA_NOFS ||
            state == Environment.MEDIA_SHARED
        val wasAvailable = previous == Environment.MEDIA_MOUNTED ||
            previous == Environment.MEDIA_MOUNTED_READ_ONLY
        if ((previous == null && isUnavailable) || (wasAvailable && isUnavailable)) {
            val epoch = storageLifecycleEpoch.incrementAndGet()
            storageLifecycleGenerations[volume] = epoch
        }
    }

    private fun mediaStoreVolumeForStorageVolume(volume: StorageVolume): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            volume.uuid?.takeIf { it.isNotBlank() } ?: "external_primary"
        } else {
            "external_primary"
        }

    private fun mediaStoreVolumeForLegacyMountIntent(intent: Intent): String? {
        val path = intent.data?.path ?: return null
        val segments = path.trim('/').split('/')
        val storageIndex = segments.indexOfFirst { it.equals("storage", ignoreCase = true) }
        if (storageIndex < 0 || storageIndex + 1 >= segments.size) return null
        val candidate = segments[storageIndex + 1]
        return when {
            candidate.equals("emulated", ignoreCase = true) ||
            candidate.equals("self", ignoreCase = true) -> "external_primary"
            candidate.isBlank() -> null
            else -> candidate
        }
    }
    private val storageManager =
        context.getSystemService(StorageManager::class.java)

    // API 29 has removable MediaStore volumes but no StorageVolumeCallback.
    // Receive the system media mount/unmount broadcasts so observer discovery
    // is refreshed when a volume appears or disappears while the engine lives.
    private val legacyStorageReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            if (disposed || intent == null) return
            when (intent.action) {
                Intent.ACTION_MEDIA_MOUNTED,
                Intent.ACTION_MEDIA_UNMOUNTED,
                Intent.ACTION_MEDIA_REMOVED,
                Intent.ACTION_MEDIA_BAD_REMOVAL,
                Intent.ACTION_MEDIA_SHARED -> {
                    // Invalidate immediately on a storage-topology change. The
                    // current observer set cannot cover a newly appearing volume
                    // until discovery/registration completes.
                    invalidateDeletionObservationBoundary()
                    recordStorageState(
                        mediaStoreVolumeForLegacyMountIntent(intent),
                        when (intent.action) {
                            Intent.ACTION_MEDIA_MOUNTED -> Environment.MEDIA_MOUNTED
                            Intent.ACTION_MEDIA_UNMOUNTED -> Environment.MEDIA_UNMOUNTED
                            Intent.ACTION_MEDIA_REMOVED -> Environment.MEDIA_REMOVED
                            Intent.ACTION_MEDIA_BAD_REMOVAL -> Environment.MEDIA_BAD_REMOVAL
                            Intent.ACTION_MEDIA_SHARED -> Environment.MEDIA_SHARED
                            else -> null
                        },
                    )
                    refreshMediaStoreObservers()
                    mediaStoreObserverHandler.removeCallbacks(mediaStoreObserverRunnable)
                    mediaStoreObserverHandler.postDelayed(mediaStoreObserverRunnable, 500)
                }
            }
        }
    }
    private var legacyStorageReceiverRegistered = false

    private val storageVolumeCallback = object : StorageManager.StorageVolumeCallback() {
        // StorageVolumeCallback is a public API-30+ callback. It reports the
        // resulting StorageVolume rather than old/new integer states.
        override fun onStateChanged(volume: StorageVolume) {
            if (disposed) return
            // Invalidate before asynchronous discovery/registration. A newly
            // mounted volume is not covered by the old observer set yet.
            invalidateDeletionObservationBoundary()
            recordStorageState(
                mediaStoreVolumeForStorageVolume(volume),
                volume.state,
            )
            // Volume lifecycle is distinct from ordinary MediaStore row
            // mutation. Refresh observer registration and schedule one
            // coalesced reconciliation so a newly mounted volume is
            // discoverable without an unrelated manual scan.
            refreshMediaStoreObservers()
            mediaStoreObserverHandler.removeCallbacks(mediaStoreObserverRunnable)
            mediaStoreObserverHandler.postDelayed(mediaStoreObserverRunnable, 500)
        }
    }

    private fun newMediaStoreObserver(): ContentObserver = object : ContentObserver(mediaStoreObserverHandler) {
        override fun onChange(selfChange: Boolean, uri: Uri?) {
            if (disposed) return
            // An item URI gives us a precise volume+ID hint. A null/collection/
            // malformed URI does not identify one row safely, so preserve an
            // explicit uncertainty bit and let Dart request identity recovery.
            var targeted = false
            if (uri != null) {
                runCatching {
                    if (uri.scheme == "content" && uri.authority == "media") {
                        val id = android.content.ContentUris.parseId(uri)
                        if (id > 0) {
                            val rawVolume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                MediaStore.getVolumeName(uri)
                            } else {
                                // Pre-Q MediaStore exposes the external collection as
                                // content://media/external/... . Those releases do not
                                // have getVolumeName(Uri), and this observer is
                                // registered against EXTERNAL_CONTENT_URI, so the only
                                // safe volume identity here is the primary external
                                // volume. Do not invent a removable-volume identity.
                                val firstPath = uri.pathSegments.firstOrNull()
                                if (firstPath == "external") "external_primary" else null
                            }
                            val volume = if (rawVolume == "external") "external_primary" else rawVolume
                            if (!volume.isNullOrBlank()) {
                                synchronized(pendingMediaStoreIdentities) {
                                    if (!pendingMediaStoreUnknown) {
                                        if (pendingMediaStoreIdentities.size < MAX_PENDING_MEDIASTORE_IDENTITIES) {
                                            pendingMediaStoreIdentities.add("$volume:$id")
                                            targeted = true
                                        } else {
                                            // The exact target set is no longer a
                                            // safe bounded representation of the
                                            // observer burst. Escalate to the
                                            // conservative reconciliation path.
                                            pendingMediaStoreUnknown = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (!targeted) {
                pendingMediaStoreUnknown = true
            }
            // True debounce: media-provider bursts collapse into one bounded
            // targeted reconciliation + incremental scan.
            mediaStoreObserverHandler.removeCallbacks(mediaStoreObserverRunnable)
            mediaStoreObserverHandler.postDelayed(mediaStoreObserverRunnable, 1000)
        }
    }

    init {
        refreshMediaStoreObservers()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            storageManager?.registerStorageVolumeCallback(
                ContextCompat.getMainExecutor(context),
                storageVolumeCallback,
            )
        } else {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_MEDIA_MOUNTED)
                addAction(Intent.ACTION_MEDIA_UNMOUNTED)
                addAction(Intent.ACTION_MEDIA_REMOVED)
                addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
                addAction(Intent.ACTION_MEDIA_SHARED)
                addDataScheme("file")
            }
            ContextCompat.registerReceiver(
                context,
                legacyStorageReceiver,
                filter,
                ContextCompat.RECEIVER_EXPORTED,
            )
            legacyStorageReceiverRegistered = true
        }
    }

    private var observerRefreshGeneration = 0L
    private val observerDiscoveryRetryRunnable = Runnable {
        if (!disposed) refreshMediaStoreObservers()
    }

    private fun refreshMediaStoreObservers() {
        if (disposed) return
        val refreshGeneration = synchronized(this) {
            observerRefreshGeneration += 1L
            observerRefreshGeneration
        }
        // Volume discovery can cross into MediaProvider/storage services. Do
        // not perform that provider work on the main thread. Registration is
        // marshalled back to main and re-checks disposal immediately before
        // touching ContentResolver, closing the dispose/registration race.
        scope.launch(Dispatchers.IO) {
            val desired = mutableSetOf<Uri>(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Volume discovery is authoritative only when it succeeds. A
                // transient MediaStore/storage-service failure must never be
                // interpreted as "there are no secondary volumes", because
                // committing that incomplete set would unregister valid
                // removable-volume observers.
                val discoveredVolumes = runCatching {
                    MediaStoreScanner.externalVolumes(context)
                }.getOrNull()

                if (discoveredVolumes == null) {
                    withContext(Dispatchers.Main.immediate) {
                        if (disposed) return@withContext
                        invalidateDeletionObservationBoundary()
                        // Keep the known-good observer set untouched. On a
                        // first-start failure there may be no observers yet,
                        // so at least retain the primary observer as a safe
                        // baseline while a later refresh retries discovery.
                        if (registeredObserverUris.isEmpty()) {
                            val primary = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                            val resolver = context.contentResolver
                            val nextObserver = newMediaStoreObserver()
                            runCatching {
                                resolver.registerContentObserver(primary, true, nextObserver)
                            }.onSuccess {
                                activeMediaStoreObserver?.let { old ->
                                    runCatching { resolver.unregisterContentObserver(old) }
                                }
                                activeMediaStoreObserver = nextObserver
                                registeredObserverUris.clear()
                                registeredObserverUris.add(primary)
                                // Volume discovery itself failed, so this is
                                // only a partial observer set. It is useful for
                                // future primary-volume events, but it is NOT a
                                // complete deletion-observation boundary.
                                deletionObservationCoverageComplete = false
                            }.onFailure {
                                runCatching { resolver.unregisterContentObserver(nextObserver) }
                                invalidateDeletionObservationBoundary()
                            }
                        }
                        mediaStoreObserverHandler.removeCallbacks(observerDiscoveryRetryRunnable)
                        mediaStoreObserverHandler.postDelayed(
                            observerDiscoveryRetryRunnable, OBSERVER_DISCOVERY_RETRY_DELAY_MS
                        )
                    }
                    return@launch
                }

                discoveredVolumes.forEach { volume ->
                    desired += MediaStore.Audio.Media.getContentUri(volume)
                }
            }
            withContext(Dispatchers.Main.immediate) {
                if (disposed) return@withContext
                val isLatest = synchronized(this@PlayerChannel) {
                    refreshGeneration == observerRefreshGeneration
                }
                if (!isLatest) return@withContext
                val resolver = context.contentResolver
                // Register the replacement observer BEFORE removing the old one.
                // ContentObserver registration is not atomic, so using the same
                // observer for both generations would make unregisterContentObserver()
                // tear down the new registrations too. A fresh observer closes the
                // mutation-loss window during refresh.
                val nextObserver = newMediaStoreObserver()
                val registered = mutableSetOf<Uri>()
                try {
                    desired.forEach { uri ->
                        if (disposed) throw IllegalStateException("disposed")
                        resolver.registerContentObserver(uri, true, nextObserver)
                        registered.add(uri)
                    }
                    val oldObserver = activeMediaStoreObserver
                    val coverageChanged = registeredObserverUris != registered
                    activeMediaStoreObserver = nextObserver
                    registeredObserverUris.clear()
                    registeredObserverUris.addAll(registered)
                    deletionObservationCoverageComplete = true
                    // Replacing an observer with an equivalent complete set is
                    // continuous coverage because the replacement is fully
                    // registered before the old observer is removed. Only a
                    // changed set (for example, a volume appearing/disappearing)
                    // invalidates an existing deletion baseline.
                    if (coverageChanged) {
                        // A changed observer set can have missed a deletion during
                        // the topology transition. Keep the boundary invalid and
                        // immediately request an identity reconciliation after the
                        // complete replacement is installed; a future observer
                        // callback cannot report a deletion that happened before
                        // this observer existed.
                        deletionObservationNeedsReconciliation = true
                        pendingMediaStoreUnknown = true
                        mediaStoreObserverHandler.removeCallbacks(mediaStoreObserverRunnable)
                        mediaStoreObserverHandler.postDelayed(
                            mediaStoreObserverRunnable, 100
                        )
                    }
                    if (oldObserver != null && oldObserver !== nextObserver) {
                        runCatching { resolver.unregisterContentObserver(oldObserver) }
                    }
                    mediaStoreObserverHandler.removeCallbacks(observerDiscoveryRetryRunnable)
                } catch (_: Exception) {
                    invalidateDeletionObservationBoundary()
                    // Roll back only the replacement. Keep the old observer set
                    // intact so a failed refresh never creates an observation gap.
                    runCatching { resolver.unregisterContentObserver(nextObserver) }
                    if (!disposed) {
                        mediaStoreObserverHandler.removeCallbacks(observerDiscoveryRetryRunnable)
                        mediaStoreObserverHandler.postDelayed(
                            observerDiscoveryRetryRunnable, OBSERVER_DISCOVERY_RETRY_DELAY_MS
                        )
                    }
                }
            }
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        synchronized(this) { observerRefreshGeneration += 1L }
        mediaStoreObserverHandler.removeCallbacksAndMessages(null)
        mediaStoreObserverHandler.removeCallbacks(observerDiscoveryRetryRunnable)
        activeMediaStoreObserver?.let { observer ->
            runCatching { context.contentResolver.unregisterContentObserver(observer) }
        }
        invalidateDeletionObservationBoundary()
        activeMediaStoreObserver = null
        registeredObserverUris.clear()
        deletionObservationCoverageComplete = false
        storageLifecycleStates.clear()
        pendingMediaStoreIdentities.clear()
        pendingMediaStoreUnknown = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            storageManager?.unregisterStorageVolumeCallback(storageVolumeCallback)
        } else if (legacyStorageReceiverRegistered) {
            runCatching { context.unregisterReceiver(legacyStorageReceiver) }
            legacyStorageReceiverRegistered = false
        }
        scope.cancel()
        // Complete every MethodChannel operation whose coroutine was cancelled
        // by the engine teardown. Kotlin coroutine cancellation alone does not
        // complete the corresponding Dart Future.
        val orphaned = pendingResults.toList()
        pendingResults.clear()
        orphaned.forEach { it.cancelForDispose() }
        // Flutter engine generations are local to one engine lifetime. The native player may
        // survive engine recreation, so invalidate the old generation namespace before the
        // next engine publishes its first library generation.
        PlayerHolder.clearLibraryGeneration()
    }

    private fun startService() {
        val intent = Intent(context, PlaybackService::class.java)
        ContextCompat.startForegroundService(context, intent)
    }

    private fun argumentLong(call: MethodCall, name: String, default: Long): Long {
        val raw = call.argument<Number>(name) ?: return default
        val value = raw.toLong()
        if (raw is Float && !raw.isFinite()) throw IllegalArgumentException("$name must be finite")
        if (raw is Double && !raw.isFinite()) throw IllegalArgumentException("$name must be finite")
        if (raw is Float && raw.toDouble() != value.toDouble()) throw IllegalArgumentException("$name must be an integer")
        if (raw is Double && raw != value.toDouble()) throw IllegalArgumentException("$name must be an integer")
        return value
    }

    private fun argumentInt(call: MethodCall, name: String, default: Int): Int {
        val value = argumentLong(call, name, default.toLong())
        require(value in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
            "$name is outside Int range"
        }
        return value.toInt()
    }

    private fun argumentNumberLong(raw: Any?, name: String): Long {
        val number = raw as? Number ?: throw IllegalArgumentException("$name must be numeric")
        val value = number.toLong()
        if (number is Float && !number.isFinite()) throw IllegalArgumentException("$name must be finite")
        if (number is Double && !number.isFinite()) throw IllegalArgumentException("$name must be finite")
        if (number is Float && number.toDouble() != value.toDouble()) throw IllegalArgumentException("$name must be an integer")
        if (number is Double && number != value.toDouble()) throw IllegalArgumentException("$name must be an integer")
        return value
    }

    override fun onMethodCall(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = trackResult(rawResult)
        if (disposed) return
        when (call.method) {
            "commitDeletionObservationBaseline" -> {
                try {
                    val epoch = call.argument<String>("epoch")?.trim()
                        ?: throw IllegalArgumentException("epoch is required")
                    result.success(commitDeletionObservationBaseline(epoch))
                } catch (e: Exception) {
                    result.error("INVALID_ARGS", e.message, null)
                }
            }

            "observerNeedsDeletionReconciliation" -> {
                result.success(observerNeedsDeletionReconciliation())
            }

            "scanLibraryIdentities" -> {
                try {
                    val volume = call.argument<String>("volume")?.trim()
                    if (volume.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "volume is required", null)
                        return
                    }
                    val rawIds = call.argument<List<Number>>("ids")
                    if (rawIds == null || rawIds.isEmpty() || rawIds.size > 500) {
                        result.error("INVALID_ARGS", "ids must contain 1..500 items", null)
                        return
                    }
                    val ids = rawIds.map { it.toLong() }
                    if (ids.any { it <= 0L }) {
                        result.error("INVALID_ARGS", "ids must be positive", null)
                        return
                    }
                    scope.launch {
                        try {
                            val rows = MediaStoreScanner.scanAudioIdentities(context, volume, ids)
                            result.success(rows.map { it.toMap() })
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            result.error("MEDIASTORE_PROVIDER_FAILED", e.message, null)
                        }
                    }
                } catch (e: Exception) {
                    result.error("INVALID_ARGS", e.message, null)
                }
            }

            "scanLibraryPage" -> {
                try {
                    val volume = call.argument<String>("volume")?.trim()
                    if (volume.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "volume is required", null)
                        return
                    }
                    val since = argumentLong(call, "sinceTimestampSeconds", 0L)
                    val until = argumentLong(call, "untilTimestampSeconds", Long.MAX_VALUE)
                    val cursorDate = argumentLong(call, "cursorDateModifiedSeconds", Long.MAX_VALUE)
                    val cursorId = argumentLong(call, "cursorMediaStoreId", Long.MAX_VALUE)
                    val sinceGeneration = argumentLong(call, "sinceGeneration", -1L)
                    val untilGeneration = argumentLong(call, "untilGeneration", -1L)
                    val cursorGeneration = argumentLong(call, "cursorGeneration", Long.MAX_VALUE)
                    require(since >= 0) { "sinceTimestampSeconds must be non-negative" }
                    require(until >= since) { "untilTimestampSeconds must be >= sinceTimestampSeconds" }
                    require(cursorDate >= 0) { "cursorDateModifiedSeconds must be non-negative" }
                    require(cursorId >= 0) { "cursorMediaStoreId must be non-negative" }
                    require(sinceGeneration >= -1L && untilGeneration >= -1L && cursorGeneration >= 0L) { "invalid generation cursor" }
                    val limit = argumentInt(call, "limit", 500)
                    require(limit in 1..1000) { "limit must be between 1 and 1000" }
                    scope.launch {
                        try {
                            val tracks = MediaStoreScanner.scanAudioPage(
                                context, volume, since, until, cursorDate, cursorId, sinceGeneration, untilGeneration, cursorGeneration, limit
                            )
                            result.success(tracks.map { it.toMap() })
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            result.error("SCAN_PAGE_FAILED", e.message, null)
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    result.error("INVALID_ARGS", e.message, null)
                }
            }

            "setLibraryGeneration" -> {
                try {
                    val generation = argumentLong(call, "generation", -1L)
                    require(generation >= 0L) { "generation must be non-negative" }
                    if (generation >= currentLibraryGeneration) {
                        currentLibraryGeneration = generation
                        PlayerHolder.setLibraryGeneration(generation)
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INVALID_ARGS", e.message, null)
                }
            }

            "getMediaStoreVolumes" -> {
                scope.launch(Dispatchers.IO) {
                    try {
                    val volumes = MediaStoreScanner.externalVolumes(context)
                    require(volumes.isNotEmpty() && volumes.all { it.isNotBlank() }) {
                        "MediaStore returned no valid volumes"
                    }
                    refreshMediaStoreObservers()
                    result.success(volumes)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("VOLUME_DISCOVERY_FAILED", e.message, null)
                    }
                }
            }

            "getMediaStoreVolumeStates" -> {
                scope.launch(Dispatchers.IO) {
                    try {
                    val volumes = MediaStoreScanner.externalVolumes(context)
                    // Keep lifecycle tokens bounded to currently known volumes,
                    // but never recreate a reinserted volume with the same token.
                    // A volume that reappears after its old entry was pruned gets a
                    // fresh process-wide epoch. This preserves the Dart-side
                    // remove/reinsert discriminator without retaining unbounded
                    // historical volume keys.
                    val present = volumes.toSet()
                    storageLifecycleGenerations.keys.retainAll(present)
                    storageLifecycleStates.keys.retainAll(present)
                    val states = volumes.map { volume ->
                        storageLifecycleGenerations.putIfAbsent(
                            volume, storageLifecycleEpoch.incrementAndGet()
                        )
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
                        mapOf(
                            "volume" to volume,
                            "generation" to generation,
                            "generationSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R),
                            "version" to version,
                            "lifecycleGeneration" to
                                (storageLifecycleGenerations[volume] ?: 0L),
                        )
                    }
                    result.success(states)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("VOLUME_STATE_FAILED", e.message, null)
                    }
                }
            }

            "findExistingMediaStoreObserverIdentities" -> {
                @Suppress("UNCHECKED_CAST")
                val rawIdentities = call.argument<List<Map<String, Any>>>("identities")
                if (rawIdentities == null) {
                    result.error("INVALID_ARGS", "identities is required", null)
                    return
                }
                scope.launch {
                    try {
                        require(rawIdentities.size <= 500) { "too many identity candidates" }
                        val candidates = rawIdentities.map { item ->
                            val volume = (item["volume"] as? String)?.trim()
                                ?.takeIf { it.isNotEmpty() }
                                ?: throw IllegalArgumentException("invalid volume")
                            val id = argumentNumberLong(item["id"], "id")
                            require(id > 0) { "id must be positive" }
                            volume to id
                        }
                        require(candidates.toSet().size == candidates.size) {
                            "duplicate identity candidates"
                        }
                        val existing = MediaStoreScanner.findExistingMediaStoreObserverIdentities(
                            context, candidates
                        )
                        result.success(existing.toList())
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("ID_OBSERVER_QUERY_FAILED", e.message, null)
                    }
                }
            }

            "findExistingMediaStoreIdentities" -> {
                @Suppress("UNCHECKED_CAST")
                val rawTracks = call.argument<List<Map<String, Any>>>("tracks")
                if (rawTracks == null) {
                    result.error("INVALID_ARGS", "tracks is required", null)
                    return
                }
                scope.launch {
                    try {
                        require(rawTracks.size <= 500) { "too many identity candidates" }
                        val candidates: List<Map<String, Any?>> = rawTracks.map { item ->
                            val volume = (item["volume"] as? String)?.trim()
                                ?.takeIf { it.isNotEmpty() }
                                ?: throw IllegalArgumentException("invalid volume")
                            val id = argumentNumberLong(item["id"], "id")
                            require(id > 0) { "id must be positive" }
                            item.mapValues { it.value } + ("volume" to volume) + ("id" to id)
                        }
                        require(candidates.map { "${it["volume"]}:${it["id"]}" }.toSet().size == candidates.size) {
                            "duplicate identity candidates"
                        }
                        val existing = MediaStoreScanner.findExistingMediaStoreIdentities(
                            context, candidates
                        )
                        result.success(existing.toList())
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("ID_FETCH_FAILED", e.message, null)
                    }
                }
            }

            // ---------------------------------------------------------
            // FIX #2: query-backed queue. `items`/`startIndex` used to
            // be the WHOLE queue; now `window`/`windowStartIndex` is
            // only an initial slice of a much larger logical result set
            // described by `spec` (opaque to native — see
            // PlaybackController/QueueSpec on the Dart side). See
            // PlayerHolder.setQueueContext / QueueWindowController for
            // how the rest of the queue is fetched on demand.
            // ---------------------------------------------------------
            "setQueueContext" -> {
                try {
                    val contextId = call.argument<String>("contextId")
                        ?.takeIf { it.isNotBlank() }
                        ?: throw IllegalArgumentException("contextId is required")
                    val queueGeneration = argumentLong(call, "queueGeneration", 0L)
                    val queueGenerationEpoch = call.argument<String>("queueGenerationEpoch")
                        ?.takeIf { it.isNotBlank() }
                        ?: throw IllegalArgumentException("queueGenerationEpoch is required")
                    require(queueGeneration > 0) { "queueGeneration must be positive" }
                    val libraryGeneration = argumentLong(call, "libraryGeneration", -1L)
                    require(libraryGeneration >= 0) { "libraryGeneration must be non-negative" }
                    val totalCount = argumentInt(call, "totalCount", 0)
                    val startIndex = argumentInt(call, "startIndex", 0)
                    val windowStartIndex = argumentInt(call, "windowStartIndex", 0)
                    val startItemIdentity = call.argument<String>("startItemIdentity")
                        ?.takeIf { it.isNotBlank() }
                    val startPositionMs = argumentLong(call, "startPositionMs", 0L)
                    require(totalCount >= 0) { "totalCount must be non-negative" }
                    require(startIndex >= 0) { "startIndex must be non-negative" }
                    require(windowStartIndex >= 0) { "windowStartIndex must be non-negative" }
                    require(startPositionMs >= 0) { "startPositionMs must be non-negative" }
                    @Suppress("UNCHECKED_CAST")
                    val rawWindow = call.argument<List<Map<String, Any>>>("window") ?: emptyList()
                    val window = rawWindow.map { m ->
                        // Keep the id a 64-bit Long end-to-end (matches
                        // MediaStore's _ID column) — .toInt() here would
                        // silently truncate/overflow on large libraries.
                        // contentUri (not a raw filesystem path) is
                        // what gets handed to ExoPlayer.
                        Pair((m["id"] as Number).toLong(), m["contentUri"] as String)
                    }

                    if (totalCount == 0 && window.isNotEmpty()) {
                        throw IllegalArgumentException("empty queue must not contain window items")
                    }
                    if (totalCount > 0 && window.isEmpty()) {
                        throw IllegalArgumentException("non-empty queue requires an initial window")
                    }
                    require(windowStartIndex <= startIndex) {
                        "windowStartIndex must not exceed startIndex"
                    }
                    if (totalCount > 0) {
                        require(windowStartIndex.toLong() + window.size <= totalCount.toLong()) {
                            "initial window exceeds queue bounds"
                        }
                        val windowIdentities = window.map { (id, uri) ->
                            val parsed = Uri.parse(uri)
                            require(parsed.scheme == "content" && parsed.authority == "media") {
                                "initial window contains an invalid MediaStore content URI"
                            }
                            // Do not silently reinterpret an URI whose volume
                            // cannot be determined as external_primary. A
                            // malformed/foreign content URI must fail closed.
                            val uriVolume = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                                MediaStore.getVolumeName(parsed)
                            } else {
                                MediaStoreScanner.identityKeyFromContentUri(id, uri).substringBeforeLast(':')
                            }
                            MediaStoreScanner.identityKey(uriVolume, id)
                        }
                        require(windowIdentities.size == windowIdentities.toSet().size) {
                            "initial window contains duplicate identities"
                        }
                    }
                    require(startIndex < totalCount || totalCount == 0) {
                        "startIndex is outside queue"
                    }
                    if (totalCount > 0 && startItemIdentity != null) {
                        val relative = startIndex - windowStartIndex
                        require(relative in window.indices) {
                            "start item is outside initial window"
                        }
                        val actual = window[relative]
                        val parsedActual = Uri.parse(actual.second)
                        require(parsedActual.scheme == "content" && parsedActual.authority == "media") {
                            "start item has an invalid MediaStore content URI"
                        }
                        val actualVolume = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                            MediaStore.getVolumeName(parsedActual)
                        } else {
                            MediaStoreScanner.identityKeyFromContentUri(actual.first, actual.second).substringBeforeLast(':')
                        }
                        val actualIdentity = MediaStoreScanner.identityKey(actualVolume, actual.first)
                        require(actualIdentity == startItemIdentity) {
                            "initial window no longer contains the requested start track"
                        }
                    }
                    startService()
                    PlayerHolder.ensureQueueController(context, channel)
                    if (!PlayerHolder.setQueueContext(
                            context,
                            contextId,
                            queueGeneration,
                            queueGenerationEpoch,
                            libraryGeneration,
                            totalCount,
                            startIndex,
                            window,
                            windowStartIndex,
                            startPositionMs,
                        )
                    ) {
                        result.error("STALE_QUEUE", "A newer queue generation is already active", null)
                        return
                    }
                    result.success(null)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    result.error("SET_QUEUE_FAILED", e.message, null)
                }
            }

            "clearQueueContextIfMatches" -> {
                try {
                    val contextId = call.argument<String>("contextId")
                        ?.takeIf { it.isNotBlank() }
                        ?: throw IllegalArgumentException("contextId is required")
                    PlayerHolder.clearQueueContextIfMatches(contextId)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("CLEAR_QUEUE_FAILED", e.message, null)
                }
            }

            "removeQueueItems" -> {
                try {
                    val identities = call.argument<List<String>>("identities") ?: emptyList()
                    PlayerHolder.removeQueueItems(identities.toSet())
                    result.success(null)
                } catch (e: Exception) {
                    result.error("REMOVE_QUEUE_FAILED", e.message, null)
                }
            }

            "refreshQueueAfterLibraryChange" -> {
                try {
                    PlayerHolder.refreshQueueAfterLibraryChange()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("REFRESH_QUEUE_FAILED", e.message, null)
                }
            }

            "getQueueContextId" -> {
                try {
                    PlayerHolder.reattachQueueProvider(channel)
                    result.success(PlayerHolder.currentQueueContextId())
                } catch (e: Exception) {
                    result.error("GET_QUEUE_CONTEXT_FAILED", e.message, null)
                }
            }

            "play" -> {
                try {
                    // PlaybackService may have been stopped while the shared
                    // PlayerHolder survived (for example after task removal
                    // while paused). Re-establish the system-facing media
                    // session/foreground-service owner before resuming.
                    startService()
                    PlayerHolder.play(context)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("PLAY_FAILED", e.message, null)
                }
            }

            "pause" -> {
                try {
                    PlayerHolder.pause(context)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("PAUSE_FAILED", e.message, null)
                }
            }

            "togglePlayPause" -> {
                try {
                    // The toggle can transition paused -> playing after the
                    // MediaSession service was destroyed. Starting the service
                    // is idempotent when it is already running and guarantees
                    // the system-facing playback owner exists before the
                    // transport state is toggled.
                    startService()
                    PlayerHolder.togglePlayPause(context)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("TOGGLE_PLAY_PAUSE_FAILED", e.message, null)
                }
            }

            "seekTo" -> {
                try {
                    val positionMs = argumentLong(call, "positionMs", 0L)
                    require(positionMs >= 0) { "positionMs must be non-negative" }
                    PlayerHolder.seekTo(context, positionMs)
                    result.success(null)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    result.error("INVALID_ARGS", e.message, null)
                }
            }

            "skipNext" -> {
                scope.launch {
                    try {
                        PlayerHolder.skipNext(context)
                        result.success(null)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("SKIP_NEXT_FAILED", e.message, null)
                    }
                }
            }

            "skipPrevious" -> {
                scope.launch {
                    try {
                        PlayerHolder.skipPrevious(context)
                        result.success(null)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("SKIP_PREVIOUS_FAILED", e.message, null)
                    }
                }
            }

            // ---------------------------------------------------------
            // Lyrics (FIX #5): embedded tags first (EmbeddedLyricsReader
            // — fast, needs no extra permission, works identically on
            // every Android version), falling back to a sidecar `.lrc`
            // file in the same folder (SidecarLyricsResolver) when the
            // track has no embedded lyrics tag. See SidecarLyricsResolver
            // for why the sidecar lookup needs two strategies to work
            // reliably across API levels under Scoped Storage.
            // ---------------------------------------------------------

            "getLyrics" -> {
                val uriString = call.argument<String>("contentUri")
                if (uriString == null) {
                    result.error("INVALID_ARGS", "contentUri is required", null)
                    return
                }
                val mediaStoreVolume = call.argument<String>("mediaStoreVolume")
                val relativePath = call.argument<String>("relativePath")
                val displayName = call.argument<String>("displayName")
                scope.launch {
                    var embeddedTransientFailure: EmbeddedLyricsReader.TransientReadException? = null
                    var embeddedProviderFailure: EmbeddedLyricsReader.ProviderException? = null
                    try {
                        val embedded = try {
                            EmbeddedLyricsReader.read(context, uriString)
                        } catch (e: EmbeddedLyricsReader.TransientReadException) {
                            embeddedTransientFailure = e
                            null
                        } catch (e: EmbeddedLyricsReader.ProviderException) {
                            embeddedProviderFailure = e
                            null
                        }
                        if (embedded != null) {
                            result.success(embedded)
                        } else {
                            val sidecar =
                                SidecarLyricsResolver.find(context, mediaStoreVolume, relativePath, displayName)
                            if (sidecar != null) {
                                result.success(sidecar)
                            } else if (embeddedProviderFailure != null) {
                                result.error(
                                    "LYRICS_PROVIDER_UNAVAILABLE",
                                    embeddedProviderFailure?.message,
                                    null,
                                )
                            } else if (embeddedTransientFailure != null) {
                                result.error(
                                    "LYRICS_PROVIDER_UNAVAILABLE",
                                    embeddedTransientFailure?.message,
                                    null,
                                )
                            } else {
                                result.success(null)
                            }
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: EmbeddedLyricsReader.TransientReadException) {
                        result.error("LYRICS_PROVIDER_UNAVAILABLE", e.message, null)
                    } catch (e: EmbeddedLyricsReader.ResourceException) {
                        result.error("LYRICS_RESOURCE_UNAVAILABLE", e.message, null)
                    } catch (e: SidecarLyricsResolver.AccessUnavailableException) {
                        result.error("LYRICS_ACCESS_UNAVAILABLE", e.message, null)
                    } catch (e: EmbeddedLyricsReader.ProviderException) {
                        result.error("LYRICS_PROVIDER_UNAVAILABLE", e.message, null)
                    } catch (e: SidecarLyricsResolver.AdmissionException) {
                        result.error("LYRICS_RESOURCE_BUSY", e.message, null)
                    } catch (e: SidecarLyricsResolver.ResourceException) {
                        result.error("LYRICS_RESOURCE_UNAVAILABLE", e.message, null)
                    } catch (e: SidecarLyricsResolver.ProviderException) {
                        result.error("LYRICS_PROVIDER_UNAVAILABLE", e.message, null)
                    } catch (e: Exception) {
                        result.error("LYRICS_READ_FAILED", e.message, null)
                    } catch (e: Error) {
                        // Provider/library Errors are not Kotlin Exceptions and
                        // would otherwise escape the coroutine without reaching
                        // the tracked MethodChannel result. Keep the call
                        // terminal; dispose() remains the final safety net.
                        result.error("LYRICS_PROVIDER_UNAVAILABLE", e.message, null)
                    }
                }
            }

            "supportsLyricsFolderRecovery" -> {
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            }

            // Whether the user has granted SAF access to at least one
            // directory tree — used by the Dart lyrics screen to decide
            // whether to offer "grant folder access" for sidecar .lrc
            // files that MediaStore.Files couldn't reach (API 33+).
            "hasLyricsFolderAccess" -> {
                val trackAware = call.hasArgument("mediaStoreVolume") ||
                    call.hasArgument("relativePath")
                val mediaStoreVolume = call.argument<String>("mediaStoreVolume")
                val relativePath = call.argument<String>("relativePath")
                scope.launch {
                    try {
                        result.success(
                            SidecarLyricsResolver.hasUsableFolderAccess(
                                context,
                                mediaStoreVolume,
                                relativePath,
                                trackAware,
                            )
                        )
                    } catch (e: CancellationException) {
                        // A cancelled coroutine must still complete the IPC
                        // contract; otherwise Dart can await this Future
                        // forever. Report cancellation as an ordinary native
                        // failure because this is an individual MethodChannel
                        // request, not a lifecycle-wide operation.
                        result.error("LYRICS_ACCESS_CANCELLED", e.message, null)
                    } catch (t: Throwable) {
                        result.error("LYRICS_ACCESS_FAILED", t.message, null)
                    }
                }
            }

            "requestLyricsFolderAccess" -> {
                launchLyricsFolderPicker(result)
            }

            // ---------------------------------------------------------
            // Album artwork: MediaStore's bounded thumbnail pipeline (API 29+)
            // — see AlbumArtLoader, which time-boxes and downsamples safely.
            // both strategies. Any failure here — expected (no artwork)
            // or not (e.g. an OutOfMemoryError from a pathological
            // embedded image) — resolves to null rather than a channel
            // error: this is a best-effort row thumbnail, not something
            // a caller should have to handle as a hard failure, and
            // catching Throwable (not just Exception) means a single
            // bad file can't crash the app from this path.
            // ---------------------------------------------------------

            "getAlbumArt" -> {
                val uriString = call.argument<String>("contentUri")
                val sizePx = (call.argument<Number>("size") ?: 256).toInt().coerceIn(32, 2048)
                val version = call.argument<Number>("version")?.toLong()
                val requestId = call.argument<String>("requestId")
                if (uriString == null || requestId == null || version == null) {
                    result.error("INVALID_ARGS", "contentUri, requestId and version are required", null)
                    return
                }
                scope.launch {
                    val bytes = try {
                        AlbumArtLoader.load(
                            context, Uri.parse(uriString), sizePx,
                            "$albumArtConsumerEpoch:$requestId", version
                        )
                    } catch (e: CancellationException) {
                        // AlbumArtLoader may cancel the shared operation when this
                        // consumer releases its last interest. A cancelled
                        // coroutine does not automatically complete the
                        // MethodChannel Result, so explicitly close this IPC
                        // request. TrackedResult makes this harmless if engine
                        // disposal already completed it.
                        result.error("ARTWORK_REQUEST_CANCELLED", e.message, null)
                        return@launch
                    } catch (e: AlbumArtLoader.AdmissionException) {
                        result.error("ARTWORK_RESOURCE_BUSY", e.message, null)
                        return@launch
                    } catch (e: AlbumArtLoader.ResourceException) {
                        // Resource exhaustion/limits are not provider failures and
                        // must not enter Dart's provider-retry loop. Dart retries
                        // only ARTWORK_RESOURCE_BUSY and ARTWORK_PROVIDER_UNAVAILABLE.
                        result.error("ARTWORK_RESOURCE_UNAVAILABLE", e.message, null)
                        return@launch
                    } catch (e: AlbumArtLoader.ProviderException) {
                        result.error("ARTWORK_PROVIDER_UNAVAILABLE", e.message, null)
                        return@launch
                    } catch (e: OutOfMemoryError) {
                        // OOM is an operational failure, not proof that the
                        // track has no artwork. Never turn it into a successful
                        // null result because Dart treats null as authoritative
                        // artwork absence.
                        result.error("ARTWORK_RESOURCE_UNAVAILABLE", "Artwork decode exhausted memory", null)
                        return@launch
                    } catch (e: Exception) {
                        result.error("ARTWORK_PROVIDER_UNAVAILABLE", e.message, null)
                        return@launch
                    }
                    result.success(bytes)
                }
            }

            // ---------------------------------------------------------
            // Equalizer / BassBoost, tied to the current player's
            // audioSessionId — see EqualizerController.
            //
            // FIX #6: audioSessionId may not be valid yet right after
            // setQueue() (ExoPlayer assigns it during/after prepare()),
            // so every entry point below goes through
            // EqualizerController.awaitAttached(), which waits
            // (event-driven + bounded-backoff retry) for a valid
            // session instead of reading audioSessionId exactly once
            // and giving up. This makes these calls suspend, hence the
            // scope.launch wrapper (previously synchronous).
            // ---------------------------------------------------------

            "getEqualizerState" -> {
                scope.launch {
                    try {
                        val player = PlayerHolder.player(context)
                        if (!EqualizerController.awaitAttached(player)) {
                            result.error("EQ_UNAVAILABLE", "Audio session/equalizer is unavailable", null)
                            return@launch
                        }
                        val state = PlayerHolder.withCurrentPlayerSession(player) { _, sessionId ->
                            EqualizerController.state(sessionId)
                        }
                        if (state == null) {
                            result.error("EQ_STALE_SESSION", "Player session changed during EQ state read", null)
                        } else {
                            result.success(state)
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("EQ_STATE_FAILED", e.message, null)
                    }
                }
            }

            "setEqualizerBand" -> {
                scope.launch {
                    try {
                        val player = PlayerHolder.player(context)
                        if (!EqualizerController.awaitAttached(player)) {
                            result.error("EQ_UNAVAILABLE", "Audio session/equalizer is unavailable", null)
                            return@launch
                        }
                        val band = (call.argument<Number>("band") ?: 0).toInt()
                        val level = (call.argument<Number>("levelMillibel") ?: 0).toInt()
                        val applied = PlayerHolder.withCurrentPlayerSession(player) { _, sessionId ->
                            EqualizerController.setBandLevel(sessionId, band, level)
                        } ?: false
                        if (!applied) {
                            result.error("EQ_SET_BAND_FAILED", "Band level could not be applied to the current audio session", null)
                            return@launch
                        }
                        result.success(null)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("EQ_SET_BAND_FAILED", e.message, null)
                    }
                }
            }

            "setEqualizerPreset" -> {
                scope.launch {
                    try {
                        val player = PlayerHolder.player(context)
                        if (!EqualizerController.awaitAttached(player)) {
                            result.error("EQ_UNAVAILABLE", "Audio session/equalizer is unavailable", null)
                            return@launch
                        }
                        val preset = (call.argument<Number>("preset") ?: 0).toInt()
                        val state = PlayerHolder.withCurrentPlayerSession(player) { _, sessionId ->
                            if (!EqualizerController.usePreset(sessionId, preset)) null
                            else EqualizerController.state(sessionId)
                        }
                        if (state == null) {
                            result.error("EQ_SET_PRESET_FAILED", "Preset could not be applied to the current audio session", null)
                            return@launch
                        }
                        result.success(state)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("EQ_SET_PRESET_FAILED", e.message, null)
                    }
                }
            }

            "setBassBoost" -> {
                scope.launch {
                    try {
                        val player = PlayerHolder.player(context)
                        if (!EqualizerController.awaitAttached(player)) {
                            result.error("EQ_UNAVAILABLE", "Audio session/equalizer is unavailable", null)
                            return@launch
                        }
                        val strength = (call.argument<Number>("strengthPermille") ?: 0).toInt()
                        val applied = PlayerHolder.withCurrentPlayerSession(player) { _, sessionId ->
                            EqualizerController.setBassBoostStrength(sessionId, strength)
                        } ?: false
                        if (!applied) {
                            result.error("EQ_BASS_FAILED", "Bass boost could not be applied to the current audio session", null)
                            return@launch
                        }
                        result.success(null)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("EQ_BASS_FAILED", e.message, null)
                    }
                }
            }

            "setEqualizerEnabled" -> {
                scope.launch {
                    try {
                        val player = PlayerHolder.player(context)
                        if (!EqualizerController.awaitAttached(player)) {
                            result.error("EQ_UNAVAILABLE", "Audio session/equalizer is unavailable", null)
                            return@launch
                        }
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        val applied = PlayerHolder.withCurrentPlayerSession(player) { _, sessionId ->
                            EqualizerController.setEnabled(sessionId, enabled)
                        } ?: false
                        if (!applied) {
                            result.error("EQ_ENABLE_FAILED", "Equalizer could not be changed on the current audio session", null)
                            return@launch
                        }
                        result.success(null)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        result.error("EQ_ENABLE_FAILED", e.message, null)
                    }
                }
            }

            // Called from EqualizerScreen.dispose() so a pending bounded
            // retry (see EqualizerController.awaitAttached) doesn't keep
            // running/holding state after the user has already left the
            // screen.
            "cancelEqualizerWait" -> {
                EqualizerController.cancelWait()
                result.success(null)
            }

            // ---------------------------------------------------------
            // Album artwork cancellation (FIX #4) — see AlbumArtLoader.
            // ---------------------------------------------------------
            "cancelAlbumArt" -> {
                val uriString = call.argument<String>("contentUri")
                val sizePx = (call.argument<Number>("size") ?: 256).toInt().coerceIn(32, 2048)
                val version = call.argument<Number>("version")?.toLong()
                val requestId = call.argument<String>("requestId")
                if (uriString != null && requestId != null && version != null) {
                    AlbumArtLoader.cancel(
                        Uri.parse(uriString), sizePx,
                        "$albumArtConsumerEpoch:$requestId", version
                    )
                }
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }
}
