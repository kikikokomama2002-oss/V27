package com.example.musicplayer.playback

import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.locks.ReentrantLock
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

/**
 * FIX #2 — COMPLETE PLAYBACK QUEUE FOR LARGE LIBRARIES AND GROUPS.
 *
 * Feeds ExoPlayer a SLIDING WINDOW of `MediaItem`s representing a slice
 * of a much larger logical, query-backed result set (see `QueueSpec`
 * on the Dart side / [QueuePageProvider] here) — never the complete
 * set. A 10,000-track "all tracks" queue costs the same native/ExoPlayer
 * memory as a 200-track one; only [MAX_LOADED_ITEMS] `MediaItem`s (tiny
 * objects — an id + a URI string, not decoded audio) are ever resident
 * in the player's playlist at once.
 *
 * As playback approaches either edge of the loaded window
 * ([onPositionChanged], driven by the player's own listener callbacks),
 * [maybeAdjustWindow] asynchronously fetches another page from
 * [pageProvider] and appends/prepends it via ExoPlayer's own
 * `addMediaItems`/`removeMediaItems`, which Media3 guarantees keeps
 * playback of the CURRENT item uninterrupted even when items well
 * before or after it are added or removed — see
 * https://developer.android.com/reference/androidx/media3/common/Player#removeMediaItem(int)
 * ("If the current item is removed ... playback ... continues");
 * removing items that are NOT the current one never affects playback
 * at all, which is the only case this class's trimming ever does.
 *
 * [skipNext]/[skipPrevious] are suspend functions: if the requested
 * direction is past the edge of what's currently loaded but the
 * logical queue has more, they await one page fetch before seeking —
 * "Next" on track #59 of a window loaded as #0..59 within a
 * 10,000-track queue still reaches #60, just with one async hop
 * instead of a synchronous one.
 */
class QueueWindowController(private val scope: CoroutineScope) {

    companion object {
        /** Fetch another page once within this many items of an edge. */
        private const val PREFETCH_TRIGGER = 15

        /** Items fetched per page request. */
        private const val FETCH_CHUNK = 60

        /**
         * Hard cap on `MediaItem`s resident in the ExoPlayer playlist at
         * once. Trimming keeps this bounded regardless of how far the
         * user has played into a huge queue — this is what actually
         * keeps memory/playlist-size bounded, matching FIX #1's
         * `WindowedPagingNotifier` cap on the Dart UI side.
         */
        private const val MAX_LOADED_ITEMS = 240

        /** Never trim closer than this to the currently playing item. */
        private const val TRIM_MARGIN = 40

        /**
         * Threshold, in ms, below which "previous" jumps to the previous
         * track instead of restarting the current one. Matches the ~3s
         * convention used by Spotify/Apple Music/most standard players.
         */
        private const val RESTART_THRESHOLD_MS = 3000L
        private const val PAGE_REQUEST_TIMEOUT_MS = 5_000L
    }

    private var player: ExoPlayer? = null
    private var pageProvider: QueuePageProvider? = null
    @Volatile private var currentLibraryGeneration: Long = 0L

    // Generation of the logical snapshot that produced the currently loaded
    // native window. -1 means the resident window is intentionally stale while
    // Dart is moving to a newer library generation. A stale window may continue
    // playing its already-loaded items, but it must never accept a page from the
    // new generation until the refresh/rebase installs a coherent replacement.
    private var windowLibraryGeneration: Long = 0L

    /** Shared non-suspending lock for every native queue state transition. */
    private inline fun <T> withMutationLock(block: () -> T): T {
        mutationMutex.lock()
        return try { block() } finally { mutationMutex.unlock() }
    }

    fun setLibraryGeneration(generation: Long) {
        withMutationLock {
            if (generation < currentLibraryGeneration) return@withMutationLock
            if (generation == currentLibraryGeneration) return@withMutationLock

            currentLibraryGeneration = generation
            // The physical ExoPlayer playlist is still from the old snapshot.
            // Invalidate every in-flight page operation and mark that window
            // stale before exposing the new generation to page validation.
            // This prevents old-window + new-page mixing. The subsequent
            // refresh/rebase is the only operation that may restore coherence.
            if (contextId != null) {
                windowLibraryGeneration = -1L
                mutationGeneration++
                windowGeneration++
                forwardFetchJob?.cancel()
                backwardFetchJob?.cancel()
            }
        }
    }

    /** Clears the Dart-engine generation namespace without destroying the surviving player/queue. */
    fun clearLibraryGeneration() {
        withMutationLock { currentLibraryGeneration = 0L }
    }

    /** True only when the resident physical playlist belongs to the current library snapshot. */
    fun isWindowLibraryGenerationCurrent(): Boolean = withMutationLock {
        windowLibraryGeneration == currentLibraryGeneration
    }

    private var contextId: String? = null
    private var totalCount: Int = 0

    /** Logical index (into the full query result set) of `loadedIds[0]`. */
    private var windowStartLogicalIndex: Int = 0

    /** Mirrors the player's playlist order — mediaId (mediaStoreId) per slot. */
    private val loadedIds = mutableListOf<String>()

    private var forwardFetchJob: Job? = null
    private var backwardFetchJob: Job? = null
    private var deletionRefreshJob: Job? = null
    private val pendingDeletionIds = mutableSetOf<String>()
    private var libraryRefreshPending = false

    /** Serializes all async queue mutations. A page response may never
     * apply concurrently with a deletion rebase or an explicit skip. */
    private val mutationMutex = ReentrantLock()
    /** Serializes user transport intents (rapid Next/Previous taps). */
    private val transportMutex = Mutex()
    /** Serializes expensive rebase resolutions so an older rebase cannot
     * complete after a newer one and overwrite its window. */
    private val rebaseMutex = Mutex()
    /** Changes whenever the loaded native window itself changes. This is
     * separate from mutationGeneration: prefetch/trim can change the window
     * without changing the logical library context. */
    private var windowGeneration = 0L
    private var mutationGeneration = 0L
    /** Increments on explicit seek/play/pause/toggle and discontinuous transport changes. */
    private var transportStateGeneration = 0L
    private var queueGenerationEpoch: String? = null
    private var queueGeneration: Long = 0L

    /**
     * Invalidates any queue navigation that was captured before an external
     * transport command. This must happen synchronously at command admission;
     * waiting for ExoPlayer's later listener callback leaves a TOCTOU window.
     */
    fun markExternalTransportCommand() {
        transportStateGeneration++
    }

    private val listener = object : Player.Listener {
        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int
        ) {
            transportStateGeneration++
            maybeAdjustWindow()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            transportStateGeneration++
            maybeAdjustWindow()
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) =
            maybeAdjustWindow()
    }

    fun attach(exoPlayer: ExoPlayer, provider: QueuePageProvider) {
        withMutationLock {
            if (player !== exoPlayer) {
                player?.removeListener(listener)
                exoPlayer.addListener(listener)
                player = exoPlayer
                // A different player instance is a different lifecycle epoch.
                // Invalidate any in-flight page commit before exposing it.
                mutationGeneration++
                windowGeneration++
            }
            pageProvider = provider
        }
    }

    /** True if [id] is anywhere in the currently loaded window. */
    fun contains(identity: String): Boolean = loadedIds.contains(identity)

    fun currentContextId(): String? = contextId

    /** Clears only [expectedContextId], never a newer queue context. */
    fun clearContextIfMatches(expectedContextId: String): Boolean {
        synchronized(this) {
            return withMutationLock {
                if (contextId != expectedContextId) return@withMutationLock false
                forwardFetchJob?.cancel()
                backwardFetchJob?.cancel()
                deletionRefreshJob?.cancel()
                forwardFetchJob = null
                backwardFetchJob = null
                deletionRefreshJob = null
                pendingDeletionIds.clear()
                libraryRefreshPending = false
                player?.clearMediaItems()
                contextId = null
                queueGenerationEpoch = null
                queueGeneration = 0L
                mutationGeneration++
                windowGeneration++
                windowLibraryGeneration = currentLibraryGeneration
                totalCount = 0
                windowStartLogicalIndex = 0
                loadedIds.clear()
                true
            }
        }
    }

    /**
     * FIX #4 — tears down this controller's state. Call from
     * [PlayerHolder.release] (player/service being destroyed) so a
     * queue-page fetch still in flight at that moment can't later
     * resume and apply its result to whatever player/context gets
     * attached the next time [attach] runs.
     *
     * Cancelling [forwardFetchJob]/[backwardFetchJob] here also
     * propagates down into [MethodChannelQueuePageProvider]'s
     * `invokeOnCancellation`, so Dart is told the in-flight request is
     * no longer wanted instead of it silently finishing unread.
     *
     * Without this, [contextId] and [player] would stay set to their
     * old values across a `release()` → re-`attach()` cycle: a job that
     * survives the release would still pass the (unchanged) `contextId
     * != cid` guard in [fetchForward]/[fetchBackward]/[skipNext]/
     * [skipPrevious], read the CURRENT [player] field at completion
     * time (by then possibly a newly re-attached, freshly-built
     * ExoPlayer that has never had [setContext] called on it), and call
     * `addMediaItems`/`removeMediaItems` on it — corrupting a player
     * instance that isn't even playing this old logical queue.
     */
    fun releaseContext() {
        withMutationLock {
            forwardFetchJob?.cancel()
            backwardFetchJob?.cancel()
            deletionRefreshJob?.cancel()
            forwardFetchJob = null
            backwardFetchJob = null
            deletionRefreshJob = null
            pendingDeletionIds.clear()
            libraryRefreshPending = false
            player?.removeListener(listener)
            player = null
            pageProvider = null
            contextId = null
            queueGenerationEpoch = null
            queueGeneration = 0L
            mutationGeneration++
            windowGeneration++
            windowLibraryGeneration = currentLibraryGeneration
            totalCount = 0
            windowStartLogicalIndex = 0
            loadedIds.clear()
        }
    }

    /**
     * Establishes a brand new queue context, replacing whatever was
     * loaded before. [window] is the initial page (already resolved by
     * Dart, centered on [startIndexGlobal] — see
     * `PlaybackController.playQueue`), [windowStartIndexGlobal] is that
     * page's own logical offset into the full result set.
     */
    fun setContext(
        newContextId: String,
        newQueueGeneration: Long,
        newQueueGenerationEpoch: String,
        expectedLibraryGeneration: Long,
        newTotalCount: Int,
        startIndexGlobal: Int,
        window: List<Pair<Long, String>>,
        windowStartIndexGlobal: Int,
        startPositionMs: Long
    ): Boolean {
        require(newQueueGeneration > 0) { "queue generation must be positive" }
        require(newQueueGenerationEpoch.isNotBlank()) { "queue generation epoch must not be blank" }
        require(newTotalCount >= 0) { "totalCount must be non-negative" }
        require(startIndexGlobal >= 0) { "startIndex must be non-negative" }
        require(windowStartIndexGlobal >= 0) { "windowStartIndex must be non-negative" }
        require(startPositionMs >= 0) { "startPositionMs must be non-negative" }
        require(windowStartIndexGlobal <= startIndexGlobal || newTotalCount == 0) {
            "windowStartIndex must not exceed startIndex"
        }
        require(newTotalCount == 0 || window.isNotEmpty()) {
            "non-empty queue requires an initial window"
        }
        require(newTotalCount == 0 ||
            windowStartIndexGlobal.toLong() + window.size <= newTotalCount.toLong()) {
            "initial window exceeds queue bounds"
        }
        require((newTotalCount == 0 && startIndexGlobal == 0 && windowStartIndexGlobal == 0) ||
            (newTotalCount > 0 && startIndexGlobal < newTotalCount)) {
            "startIndex is outside queue"
        }
        val identities = window.map { identityKey(it.first, it.second) }
        require(identities.size == identities.toSet().size) {
            "initial window contains duplicate identities"
        }
        require(window.all { it.second.isNotBlank() &&
            android.net.Uri.parse(it.second).scheme == "content" }) {
            "initial window contains an invalid content URI"
        }
        if (newTotalCount > 0) {
            val relative = startIndexGlobal - windowStartIndexGlobal
            require(relative in window.indices) {
                "start item is outside initial window"
            }
        }

        // Native MethodChannel calls can overlap. Serialize the generation
        // check together with the complete installation so A cannot validate,
        // get preempted by B, and then install after B.
        return withMutationLock {
            val p = player ?: return@withMutationLock false
            if (expectedLibraryGeneration != currentLibraryGeneration) return@withMutationLock false
            if (queueGenerationEpoch == newQueueGenerationEpoch &&
                newQueueGeneration <= queueGeneration
            ) {
                return false
            }
            if (queueGenerationEpoch != newQueueGenerationEpoch) {
                queueGenerationEpoch = newQueueGenerationEpoch
                queueGeneration = 0L
            }
            queueGeneration = newQueueGeneration

            forwardFetchJob?.cancel()
            backwardFetchJob?.cancel()
            deletionRefreshJob?.cancel()
            pendingDeletionIds.clear()
            libraryRefreshPending = false
            mutationGeneration++
            windowGeneration++

            contextId = newContextId
            windowLibraryGeneration = expectedLibraryGeneration
            totalCount = newTotalCount
            windowStartLogicalIndex = windowStartIndexGlobal
            loadedIds.clear()
            loadedIds.addAll(window.map { identityKey(it.first, it.second) })

            val mediaItems = window.map { (id, uri) -> toMediaItem(id, uri) }
            if (mediaItems.isEmpty()) {
                // Never leave the previous queue playing if a replacement
                // context arrives with an empty/invalid initial page.
                p.clearMediaItems()
                return true
            }
            val relativeStart =
                (startIndexGlobal - windowStartIndexGlobal).coerceIn(0, mediaItems.size - 1)

            p.setMediaItems(mediaItems, relativeStart, startPositionMs)
            p.prepare()
            p.playWhenReady = true
            return true
        }
    }

    /**
     * Prunes any loaded item(s) matching [ids] — e.g. tracks deleted
     * from device storage while this queue is active (FIX #2). Safe to
     * call with ids not present in the window (no-op for those).
     */
    fun removeItems(ids: Set<String>) {
        withMutationLock {
            if (contextId == null || ids.isEmpty()) return@withMutationLock
            pendingDeletionIds.addAll(ids)
            mutationGeneration++
            forwardFetchJob?.cancel()
            backwardFetchJob?.cancel()
        }
        scheduleLibraryMutationRefresh()
    }

    private fun scheduleLibraryMutationRefresh() {
        if (deletionRefreshJob?.isActive == true) return
        val cid = contextId ?: return
        deletionRefreshJob = scope.launch {
            // Coalesce bursts of MediaStore deletion batches and scan-change
            // invalidations into one ordered refresh. A later deletion can
            // never cancel an earlier refresh and leave its ids stranded.
            kotlinx.coroutines.delay(25)
            while (true) {
                val batch = pendingDeletionIds.toSet()
                pendingDeletionIds.removeAll(batch)
                val refresh = libraryRefreshPending
                libraryRefreshPending = false
                if (batch.isEmpty() && !refresh) break
                if (contextId == cid) {
                    // Rebase performs platform/Isar round-trips. Do not hold
                    // the short-lived mutation mutex across those awaits;
                    // the rebase itself re-acquires the mutex only for its
                    // final ExoPlayer/state commit and re-checks generation.
                    rebaseAfterLibraryMutation(cid, batch)
                }
                if (pendingDeletionIds.isEmpty() && !libraryRefreshPending) break
            }
            deletionRefreshJob = null
            // A new mutation may have arrived in the tiny gap after the loop
            // check and before the job reference was cleared.
            if (pendingDeletionIds.isNotEmpty() || libraryRefreshPending) {
                scheduleLibraryMutationRefresh()
            }
        }
    }

    /** Re-resolves the native window around a surviving/current identity. */
    private suspend fun rebaseAfterLibraryMutation(cid: String, removedIds: Set<String>): Unit =
        rebaseMutex.withLock {
        val currentPlayer = player ?: return@withLock
        val currentIndex = currentPlayer.currentMediaItemIndex
        if (currentIndex < 0 || currentIndex >= loadedIds.size) return
        val generation = mutationGeneration
        val capturedWindowGeneration = windowGeneration
        val capturedTransportStateGeneration = transportStateGeneration

        val currentId = loadedIds[currentIndex]
        val currentPlayerMediaId = currentPlayer.currentMediaItem?.mediaId
        val currentPlayerPositionToken = currentIndex to currentPlayerMediaId
        val provider = pageProvider ?: return

        // Deletion notifications cross the Dart/Isar -> native boundary and
        // are therefore inherently non-atomic with a delete/reinsert race.
        // Before treating a notification as authoritative, re-check loaded
        // identities against the current logical queue. A recreated identity
        // that is already back in the queue must not be evicted by the stale
        // notification. If the provider cannot prove the identity is present
        // (timeout/indeterminate), retain the deletion decision; a later
        // library-generation refresh will rebase the window authoritatively.
        var effectiveRemovedIds = removedIds
        val relevantRemovedIds = removedIds.intersect(loadedIds.toSet())
        if (relevantRemovedIds.isNotEmpty()) {
            val reappearedIds = coroutineScope {
                val semaphore = Semaphore(4)
                val checks = withTimeoutOrNull(PAGE_REQUEST_TIMEOUT_MS) {
                    relevantRemovedIds.mapNotNull { identity ->
                        val parsed = parseIdentity(identity) ?: return@mapNotNull null
                        async {
                            semaphore.withPermit {
                                val page = requestPageAroundIdentityWithTimeout(
                                    provider, cid, parsed.first, parsed.second, 0, 1
                                )
                                identity to (page?.items?.any { item ->
                                    item.first == parsed.second
                                } == true)
                            }
                        }
                    }.awaitAll()
                }.orEmpty()
                checks.filter { it.second }.map { it.first }.toSet()
            }
            if (reappearedIds.isNotEmpty()) {
                effectiveRemovedIds = removedIds - reappearedIds
            }
        }

        val candidateIds = buildList {
            if (currentId !in effectiveRemovedIds) add(currentId)
            addAll(
                loadedIds.drop(currentIndex + 1)
                    .filter { it !in effectiveRemovedIds }
                    .take(8)
            )
            addAll(
                loadedIds.take(currentIndex)
                    .asReversed()
                    .filter { it !in effectiveRemovedIds }
                    .take(8)
            )
        }.distinct()

        // A track can legitimately leave the active query without being
        // deleted (e.g. a search result stops matching after metadata changes).
        // Try surviving loaded identities in playback-nearest order until one
        // still belongs to the current query. If none does, fall back to the
        // old logical window position rather than abandoning the queue.
        var anchorId: String? = null
        var result: QueuePageResult? = null
        // Probe candidates concurrently with a single total deadline instead
        // of serial 5-second timeouts. The old serial path could spend 17 x
        // 5s = 85s before reaching fallback. A small bounded fan-out keeps
        // provider pressure controlled while making the rebase deadline
        // independent of the number of candidates.
        coroutineScope {
            val candidates = candidateIds.mapNotNull { candidate ->
                val parsed = parseIdentity(candidate) ?: return@mapNotNull null
                candidate to parsed
            }
            val probeResults = withTimeoutOrNull(PAGE_REQUEST_TIMEOUT_MS) {
                val semaphore = Semaphore(4)
                candidates.map { (candidate, parsed) ->
                    async {
                        semaphore.withPermit {
                            val page = requestPageAroundIdentityWithTimeout(
                                provider, cid, parsed.first, parsed.second, 40, 160
                            )
                            candidate to page
                        }
                    }
                }.awaitAll()
            }.orEmpty()
            if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                contextId != cid) return@coroutineScope
            val winner = probeResults.firstOrNull { (_, page) -> !page?.items.isNullOrEmpty() }
            if (winner != null) {
                anchorId = winner.first
                result = winner.second
            }
        }

        if (result == null) {
            result = requestPageWithTimeout(
                provider,
                cid,
                windowStartLogicalIndex.coerceAtLeast(0),
                MAX_LOADED_ITEMS,
            )
            if (result?.items.isNullOrEmpty() && windowStartLogicalIndex > 0) {
                // The query may have shrunk so much that the old logical
                // offset is now beyond its end. Stay as close as possible to
                // the old playback position instead of jumping all the way
                // back to track 0. The bounded tail offset also handles a
                // very large queue without probing one old index at a time.
                val newTotal = result?.totalCount ?: 0
                val fallbackOffset = (newTotal - MAX_LOADED_ITEMS).coerceAtLeast(0)
                result = requestPageWithTimeout(
                    provider, cid, fallbackOffset, MAX_LOADED_ITEMS
                )
            }
        }
        val resolved = result ?: return
        if (resolved.items.isNotEmpty() && !isValidPage(resolved)) return
        var retryForNavigation = false
        withMutationLock {
            // All provider/Isar work above happened without the mutex. A
            // mutation or another queue operation may therefore have won
            // while the page was in flight; never install its stale result.
            if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                capturedTransportStateGeneration != transportStateGeneration ||
                contextId != cid ||
                player !== currentPlayer) return@withLock
            // Navigation can occur while the asynchronous rebase is resolving
            // pages. Never commit a rebase computed from an obsolete playback
            // position/identity; let the later transition callback schedule a
            // fresh rebase instead.
            val livePositionToken = currentPlayer.currentMediaItemIndex to
                currentPlayer.currentMediaItem?.mediaId
            if (livePositionToken != currentPlayerPositionToken) {
                retryForNavigation = true
                return@withLock
            }

            totalCount = resolved.totalCount
            if (resolved.items.isEmpty()) {
                loadedIds.clear()
                currentPlayer.clearMediaItems()
                windowStartLogicalIndex = resolved.startIndex.coerceAtLeast(0)
                return@withLock
            }

            val target = resolved.items.take(MAX_LOADED_ITEMS)
            val targetIds = target.map { identityKey(it.first, it.second) }
            val oldCurrentId = currentPlayer.currentMediaItem?.mediaId
            val oldPosition = currentPlayer.currentPosition.coerceAtLeast(0L)
            val wasPlaying = currentPlayer.playWhenReady
            val oldLogicalIndex = windowStartLogicalIndex + currentIndex
            val targetIndex = when {
                oldCurrentId != null && oldCurrentId in targetIds && oldCurrentId !in effectiveRemovedIds ->
                    targetIds.indexOf(oldCurrentId)
                anchorId != null && anchorId in targetIds -> targetIds.indexOf(anchorId)
                else -> (oldLogicalIndex - resolved.startIndex).coerceIn(0, target.lastIndex)
            }

            windowStartLogicalIndex = resolved.startIndex
            windowLibraryGeneration = currentLibraryGeneration
            loadedIds.clear()
            loadedIds.addAll(targetIds)
            windowGeneration++
            currentPlayer.setMediaItems(
                target.map { (id, uri) -> toMediaItem(id, uri) },
                targetIndex.coerceIn(0, target.lastIndex),
                if (oldCurrentId != null && oldCurrentId == targetIds.getOrNull(targetIndex)) oldPosition else 0L,
            )
            currentPlayer.prepare()
            currentPlayer.playWhenReady = wasPlaying
        }
        if (retryForNavigation && contextId == cid) {
            // Navigation won the race. Re-resolve around the new live
            // playback identity rather than silently consuming the pending
            // library mutation with an obsolete anchor.
            scope.launch {
                if (contextId == cid) {
                    rebaseAfterLibraryMutation(cid, removedIds)
                }
            }
            return
        }
        maybeAdjustWindow()
    }

    /** Called for inserts/metadata updates; current identity remains the anchor. */
    fun refreshAfterLibraryChange() {
        withMutationLock {
            if (contextId == null) return@withMutationLock
            libraryRefreshPending = true
            mutationGeneration++
            forwardFetchJob?.cancel()
            backwardFetchJob?.cancel()
        }
        scheduleLibraryMutationRefresh()
    }

    /** True if there's more logical queue beyond what's currently loaded/playing. */
    private fun logicalIndexOf(relative: Int) = windowStartLogicalIndex + relative

    private fun maybeAdjustWindow() {
        val p = player ?: return
        val cid = contextId ?: return
        val currentRelative = p.currentMediaItemIndex
        if (currentRelative < 0 || currentRelative >= loadedIds.size) return

        val itemsAheadLoaded = loadedIds.size - 1 - currentRelative
        val itemsBehindLoaded = currentRelative

        val hasMoreForward = windowStartLogicalIndex + loadedIds.size < totalCount
        val hasMoreBackward = windowStartLogicalIndex > 0

        if (itemsAheadLoaded < PREFETCH_TRIGGER && hasMoreForward) {
            fetchForward(cid)
        }
        if (itemsBehindLoaded < PREFETCH_TRIGGER && hasMoreBackward) {
            fetchBackward(cid)
        }
        trimIfNeeded()
    }

    private fun fetchForward(cid: String) {
        if (forwardFetchJob?.isActive == true) return
        val provider = pageProvider ?: return
        val offset = windowStartLogicalIndex + loadedIds.size
        if (offset >= totalCount) return
        val limit = minOf(FETCH_CHUNK, totalCount - offset)
        if (limit <= 0) return

        val generation = mutationGeneration
        val capturedWindowGeneration = windowGeneration
        forwardFetchJob = scope.launch {
            val result = requestPageWithTimeout(provider, cid, offset, limit) ?: return@launch
            var needsRebase = false
            withMutationLock mutationLock@{
                if (generation != mutationGeneration ||
                    capturedWindowGeneration != windowGeneration ||
                    contextId != cid) return@mutationLock
                val p = player ?: return@mutationLock
                // Validate untrusted provider data before deriving identities.
                // identityKey() is intentionally strict and throws for malformed
                // MediaStore rows; background prefetch must reject such a page,
                // not turn corrupt data into an uncaught coroutine exception.
                if (windowLibraryGeneration != currentLibraryGeneration) return@mutationLock
                if (!isValidPage(result, offset) || result.libraryGeneration != currentLibraryGeneration) return@mutationLock
                val overlaps = result.items.any {
                    identityKey(it.first, it.second) in loadedIds
                }
                if (overlaps) {
                    totalCount = result.totalCount
                    needsRebase = true
                    return@mutationLock
                }
                totalCount = result.totalCount
                p.addMediaItems(result.items.map { (id, uri) -> toMediaItem(id, uri) })
                loadedIds.addAll(result.items.map { identityKey(it.first, it.second) })
                windowGeneration++
                trimIfNeeded()
            }
            if (needsRebase &&
                generation == mutationGeneration &&
                capturedWindowGeneration == windowGeneration &&
                contextId == cid) {
                rebaseAfterLibraryMutation(cid, emptySet())
            }
        }
    }

    private fun fetchBackward(cid: String) {
        if (backwardFetchJob?.isActive == true) return
        val provider = pageProvider ?: return
        if (windowStartLogicalIndex <= 0) return
        val limit = minOf(FETCH_CHUNK, windowStartLogicalIndex)
        val offset = windowStartLogicalIndex - limit
        if (limit <= 0) return

        val generation = mutationGeneration
        val capturedWindowGeneration = windowGeneration
        backwardFetchJob = scope.launch {
            val result = requestPageWithTimeout(provider, cid, offset, limit) ?: return@launch
            var needsRebase = false
            withMutationLock mutationLock@{
                if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                contextId != cid) return@mutationLock
                val p = player ?: return@mutationLock
                // Validate untrusted provider data before deriving identities.
                // identityKey() is intentionally strict and throws for malformed
                // MediaStore rows; background prefetch must reject such a page,
                // not turn corrupt data into an uncaught coroutine exception.
                if (windowLibraryGeneration != currentLibraryGeneration) return@mutationLock
                if (!isValidPage(result, offset) || result.libraryGeneration != currentLibraryGeneration) return@mutationLock
                val overlaps = result.items.any {
                    identityKey(it.first, it.second) in loadedIds
                }
                if (overlaps) {
                    totalCount = result.totalCount
                    needsRebase = true
                    return@mutationLock
                }
                totalCount = result.totalCount
                p.addMediaItems(0, result.items.map { (id, uri) -> toMediaItem(id, uri) })
                loadedIds.addAll(0, result.items.map { identityKey(it.first, it.second) })
                windowStartLogicalIndex = result.startIndex
                windowGeneration++
                trimIfNeeded()
            }
            if (needsRebase &&
                generation == mutationGeneration &&
                capturedWindowGeneration == windowGeneration &&
                contextId == cid) {
                rebaseAfterLibraryMutation(cid, emptySet())
            }
        }
    }

    /**
     * Bounds [loadedIds]/the player playlist to [MAX_LOADED_ITEMS],
     * trimming from whichever side has more slack relative to the
     * currently playing item — per the Media3 contract cited in the
     * class doc, removing items that aren't the current one never
     * disrupts playback.
     */
    private fun trimIfNeeded() {
        val p = player ?: return
        var changed = false
        while (loadedIds.size > MAX_LOADED_ITEMS) {
            val currentRelative = p.currentMediaItemIndex.coerceIn(0, loadedIds.size - 1)
            val behind = currentRelative
            val ahead = loadedIds.size - 1 - currentRelative

            if (behind > ahead && behind > TRIM_MARGIN) {
                val trimCount = minOf(FETCH_CHUNK, behind - TRIM_MARGIN)
                if (trimCount <= 0) break
                p.removeMediaItems(0, trimCount)
                repeat(trimCount) { loadedIds.removeAt(0) }
                windowStartLogicalIndex += trimCount
                changed = true
            } else if (ahead > TRIM_MARGIN) {
                val trimCount = minOf(FETCH_CHUNK, ahead - TRIM_MARGIN)
                if (trimCount <= 0) break
                val fromIndex = loadedIds.size - trimCount
                p.removeMediaItems(fromIndex, loadedIds.size)
                repeat(trimCount) { loadedIds.removeAt(loadedIds.size - 1) }
                changed = true
            } else {
                // Neither side has enough slack beyond the trim margin —
                // stop rather than trimming into the margin itself.
                break
            }
        }
        if (changed) windowGeneration++
    }

    /**
     * Advances to the next track, awaiting a forward page fetch first
     * if playback is at the edge of the loaded window but more exists
     * logically. Returns false only once truly at the end of the
     * queue.
     */
    suspend fun skipNext(): Boolean = transportMutex.withLock transportLock@{
        val p = player ?: return@transportLock false
        val cid = contextId ?: return@transportLock false
        if (p.hasNextMediaItem() && isWindowLibraryGenerationCurrent()) {
            markExternalTransportCommand()
            p.seekToNextMediaItem()
            return@transportLock true
        }
        if (p.hasNextMediaItem() && !isWindowLibraryGenerationCurrent()) {
            // The physical neighbor belongs to an older library snapshot.
            // Rebase before consuming it; never let a stale playlist bypass
            // the same generation contract used by page-based navigation.
            rebaseAfterLibraryMutation(cid, emptySet())
            if (contextId != cid) return@transportLock false
            if (isWindowLibraryGenerationCurrent() && p.hasNextMediaItem()) {
                p.seekToNextMediaItem()
                return@transportLock true
            }
        }

        val generation = mutationGeneration
        val capturedWindowGeneration = windowGeneration
        val capturedTransportStateGeneration = transportStateGeneration
        val currentGlobal = logicalIndexOf(p.currentMediaItemIndex.coerceAtLeast(0))
        if (currentGlobal + 1 >= totalCount) return@transportLock false

        val provider = pageProvider ?: throw IllegalStateException("NEXT_PAGE_UNAVAILABLE")
        val offset = windowStartLogicalIndex + loadedIds.size
        val limit = minOf(FETCH_CHUNK, totalCount - offset)
        if (limit <= 0) return@transportLock false

        val result = requestPageWithTimeout(provider, cid, offset, limit)
            ?: throw IllegalStateException("NEXT_PAGE_UNAVAILABLE")

        if (generation != mutationGeneration ||
            capturedTransportStateGeneration != transportStateGeneration ||
            contextId != cid) {
            // A real queue/transport mutation won while the page was in
            // flight. Never act on that stale transport operation.
            return@transportLock false
        }

        if (capturedWindowGeneration != windowGeneration) {
            // A concurrent background prefetch may have successfully appended
            // the exact next page. That is not an invalidation of the user's
            // transport intent: re-evaluate the now-current player window.
            // In particular, do not lose a physical Next tap merely because
            // prefetch incremented windowGeneration first.
            if (windowLibraryGeneration == currentLibraryGeneration &&
                p.hasNextMediaItem()) {
                p.seekToNextMediaItem()
                return@transportLock true
            }
            return@transportLock false
        }

        var needsRebase = false
        withMutationLock mutationLock@{
            if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                contextId != cid) return@mutationLock

            if (windowLibraryGeneration != currentLibraryGeneration) return@mutationLock

            if (!isValidPage(result, offset)) {
                throw IllegalStateException("NEXT_PAGE_INVALID")
            }

            if (result.items.any { identityKey(it.first, it.second) in loadedIds }) {
                totalCount = result.totalCount
                needsRebase = true
                return@mutationLock
            }

            totalCount = result.totalCount
            p.addMediaItems(result.items.map { (id, uri) -> toMediaItem(id, uri) })
            loadedIds.addAll(result.items.map { identityKey(it.first, it.second) })
            windowGeneration++
        }

        if (needsRebase) {
            if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                contextId != cid) {
                return@transportLock false
            }
            rebaseAfterLibraryMutation(cid, emptySet())
            if (contextId != cid) return@transportLock false
            if (p.hasNextMediaItem()) {
                p.seekToNextMediaItem()
                return@transportLock true
            }
            return@transportLock false
        }

        if (generation != mutationGeneration ||
            capturedTransportStateGeneration != transportStateGeneration ||
            contextId != cid) {
            return@transportLock false
        }

        if (!p.hasNextMediaItem()) return@transportLock false
        p.seekToNextMediaItem()
        true
    }

    /**
     * Standard music-player previous behavior. Transport intents are
     * serialized so two rapid taps cannot both observe the same edge and
     * race to insert/seek the same page. Queue mutations still invalidate
     * an in-flight operation through [mutationGeneration].
     */
    suspend fun skipPrevious(): Boolean = transportMutex.withLock transportLock@{
        val p = player ?: return@transportLock false
        // Admit the external Previous intent before any synchronous or
        // asynchronous branch. Direct seek-to-zero paths are transport
        // mutations too and must invalidate an in-flight queue navigation.
        markExternalTransportCommand()
        if (p.currentPosition > RESTART_THRESHOLD_MS) {
            p.seekTo(0)
            return@transportLock true
        }
        val cid = contextId ?: run {
            p.seekTo(0)
            return@transportLock true
        }
        if (p.hasPreviousMediaItem() && isWindowLibraryGenerationCurrent()) {
            p.seekToPreviousMediaItem()
            return@transportLock true
        }
        if (p.hasPreviousMediaItem() && !isWindowLibraryGenerationCurrent()) {
            rebaseAfterLibraryMutation(cid, emptySet())
            if (contextId != cid) return@transportLock false
            if (isWindowLibraryGenerationCurrent() && p.hasPreviousMediaItem()) {
                p.seekToPreviousMediaItem()
                return@transportLock true
            }
        }

        if (windowStartLogicalIndex <= 0) {
            p.seekTo(0)
            return@transportLock true
        }

        val provider = pageProvider ?: throw IllegalStateException("PREVIOUS_PAGE_UNAVAILABLE")
        val generation = mutationGeneration
        val capturedWindowGeneration = windowGeneration
        val capturedTransportStateGeneration = transportStateGeneration
        val limit = minOf(FETCH_CHUNK, windowStartLogicalIndex)
        val offset = windowStartLogicalIndex - limit
        val result = requestPageWithTimeout(provider, cid, offset, limit)
            ?: throw IllegalStateException("PREVIOUS_PAGE_UNAVAILABLE")

        if (generation != mutationGeneration ||
            capturedTransportStateGeneration != transportStateGeneration ||
            contextId != cid) {
            // Another real queue/transport mutation won the race. Leave playback
            // untouched rather than acting on stale logical data.
            return@transportLock false
        }

        if (capturedWindowGeneration != windowGeneration) {
            // A successful backward prefetch changed only the physical window
            // generation. Re-evaluate the live player instead of dropping the
            // user's Previous intent.
            if (windowLibraryGeneration == currentLibraryGeneration &&
                p.hasPreviousMediaItem()) {
                p.seekToPreviousMediaItem()
                return@transportLock true
            }
            return@transportLock false
        }

        var needsRebase = false
        withMutationLock mutationLock@{
            if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                contextId != cid) return@mutationLock

            if (windowLibraryGeneration != currentLibraryGeneration) return@mutationLock

            if (!isValidPage(result, offset)) {
                throw IllegalStateException("PREVIOUS_PAGE_INVALID")
            }

            if (result.items.any { identityKey(it.first, it.second) in loadedIds }) {
                totalCount = result.totalCount
                needsRebase = true
                return@mutationLock
            }

            totalCount = result.totalCount
            p.addMediaItems(0, result.items.map { (id, uri) -> toMediaItem(id, uri) })
            loadedIds.addAll(0, result.items.map { identityKey(it.first, it.second) })
            windowStartLogicalIndex = result.startIndex
            windowGeneration++
        }

        if (needsRebase) {
            if (generation != mutationGeneration ||
                capturedWindowGeneration != windowGeneration ||
                contextId != cid) {
                return@transportLock false
            }
            rebaseAfterLibraryMutation(cid, emptySet())
            if (contextId != cid) return@transportLock false
            if (p.hasPreviousMediaItem()) {
                p.seekToPreviousMediaItem()
                return@transportLock true
            }
            p.seekTo(0)
            return@transportLock true
        }

        if (generation != mutationGeneration ||
            capturedTransportStateGeneration != transportStateGeneration ||
            contextId != cid) {
            return@transportLock false
        }

        if (p.hasPreviousMediaItem()) {
            p.seekToPreviousMediaItem()
            true
        } else {
            p.seekTo(0)
            true
        }
    }

    private fun isValidPage(result: QueuePageResult, expectedStart: Int? = null): Boolean {
        if (result.libraryGeneration < 0L || result.libraryGeneration != currentLibraryGeneration) return false
        if (result.totalCount < 0 || result.startIndex < 0) return false
        if (expectedStart != null && result.startIndex != expectedStart) return false
        if (result.items.isEmpty()) return false
        if (result.startIndex.toLong() + result.items.size > result.totalCount.toLong()) return false
        if (result.items.any { it.second.isBlank() }) return false
        val identities = result.items.mapNotNull { tryIdentityKey(it.first, it.second) }
        if (identities.size != result.items.size) return false
        return identities.size == identities.toSet().size
    }

    private suspend fun requestPageWithTimeout(
        provider: QueuePageProvider,
        cid: String,
        offset: Int,
        limit: Int,
    ): QueuePageResult? =
        withTimeoutOrNull(PAGE_REQUEST_TIMEOUT_MS) {
            provider.requestPage(cid, offset, limit)
        }

    private suspend fun requestPageAroundIdentityWithTimeout(
        provider: QueuePageProvider,
        cid: String,
        volume: String,
        mediaStoreId: Long,
        before: Int,
        after: Int,
    ): QueuePageResult? =
        withTimeoutOrNull(PAGE_REQUEST_TIMEOUT_MS) {
            provider.requestPageAroundIdentity(cid, volume, mediaStoreId, before, after)
        }

    private fun parseIdentity(identity: String): Pair<String, Long>? {
        val separator = identity.lastIndexOf(':')
        if (separator <= 0 || separator == identity.lastIndex) return null
        val volume = identity.substring(0, separator)
        val id = identity.substring(separator + 1).toLongOrNull() ?: return null
        return volume to id
    }

    /**
     * Converts untrusted queue-page identity data without throwing. Background
     * page/rebase paths use this only for validation; the strict identityKey()
     * remains the canonical constructor for already-validated queue items.
     */
    private fun tryIdentityKey(id: Long, contentUri: String): String? =
        runCatching { identityKey(id, contentUri) }.getOrNull()

    private fun identityKey(id: Long, contentUri: String): String {
        require(id > 0L) { "invalid MediaStore id" }
        val uri = android.net.Uri.parse(contentUri)
        require(uri.scheme == "content" && uri.authority == "media") {
            "invalid MediaStore content URI"
        }
        val primaryVolume = "external_primary"
        val volume = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            android.provider.MediaStore.getVolumeName(uri)
        } else {
            primaryVolume
        }
        val normalizedVolume = if (volume == "external") primaryVolume else volume
        require(normalizedVolume.isNotBlank()) { "MediaStore volume is unavailable" }
        return "$normalizedVolume:$id"
    }

    private fun toMediaItem(id: Long, contentUri: String): MediaItem =
        MediaItem.Builder().setMediaId(identityKey(id, contentUri)).setUri(contentUri).build()
}
