package com.example.musicplayer.playback

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.session.SessionResult
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.SupervisorJob

/**
 * Process-wide singleton holding the single ExoPlayer instance.
 *
 * Both the foreground [PlaybackService] (for lock-screen/notification/
 * Bluetooth integration) and the Flutter [PlayerChannel] / event channel
 * talk to the SAME player instance, so transport commands issued from
 * Dart and hardware button events stay in sync.
 *
 * SAFETY NOTE: [player] used to be a `lateinit var`, which crashed with
 * `lateinit property player has not been initialized` if anything (most
 * commonly the EventChannel's `onListen`, which can fire as soon as the
 * Flutter engine attaches — before any queue call has happened) touched
 * it before [init] ran. `player` is now nullable and every access goes
 * through [init]-guaranteeing accessors, so nothing can observe an
 * uninitialized player anymore, regardless of call order.
 *
 * FIX #2: playback queues are now query-backed rather than a concrete
 * `List<MediaItem>` handed over up front — see [QueueWindowController],
 * which this object delegates all queue/skip logic to.
 */
object PlayerHolder {

    @Volatile
    private var _player: ExoPlayer? = null

    // Own supervisor scope (survives individual queue-page-fetch
    // failures) for QueueWindowController's async prefetch/skip work —
    // distinct from PlayerChannel's per-call `scope.launch` since this
    // needs to keep running (e.g. a prefetch triggered by a player
    // event) independent of any single MethodChannel call's lifetime.
    private val queueScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val queueWindowController = QueueWindowController(queueScope)

    /** Caps queued same-direction transport intents (see the pending-count
     * fields below) so a stuck controller or runaway button repeat can't
     * queue an unbounded number of pending skips. */
    private const val MAX_PENDING_TRANSPORT_INTENTS = 8
    private var mediaSessionSkipNextJob: Job? = null
    private var mediaSessionSkipPreviousJob: Job? = null
    // Counts (not just flags) queued transport intents that arrived while a
    // skip was already in flight, so a burst of same-direction button
    // presses results in that many navigations run in order instead of a
    // single Boolean's "at least one more happened" collapsing everything
    // past the first into one. Bounded by MAX_PENDING_TRANSPORT_INTENTS: a
    // stuck/misbehaving controller cannot queue an unlimited number of
    // pending skips, and any intents beyond that bound are intentionally
    // dropped rather than queued — see the admission checks below.
    private var mediaSessionSkipNextPendingCount = 0
    private var mediaSessionSkipPreviousPendingCount = 0
    private var headlessQueueRuntime: HeadlessFlutterQueueRuntime? = null

    /**
     * The live ExoPlayer instance. Always safe to call — lazily
     * initializes on first access from any thread/entry point (service
     * creation, a MethodChannel call, or the EventChannel attaching)
     * instead of assuming a particular startup order.
     */
    @Synchronized
    fun player(context: Context): ExoPlayer {
        return _player ?: buildPlayer(context.applicationContext).also { _player = it }
    }

    /**
     * Non-initializing accessor for call sites that must not have side
     * effects (e.g. a background listener deciding whether to bother
     * emitting state). Returns null if the player hasn't been created
     * yet instead of crashing or forcing creation.
     */
    fun peek(): ExoPlayer? = _player

    private fun buildPlayer(context: Context): ExoPlayer {
        val player = ExoPlayer.Builder(context)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true
            )
            .setSkipSilenceEnabled(false)
            .build()
        player.repeatMode = Player.REPEAT_MODE_OFF
        return player
    }

    /**
     * Wires [queueWindowController] to the live player + a Dart-backed
     * [QueuePageProvider]. Idempotent (re-attaching to the same player
     * is a no-op) — safe to call from every entry point that touches
     * the player, matching [player]'s own lazy-init safety story.
     */
    @Synchronized
    fun ensureQueueController(context: Context, methodChannel: MethodChannel): QueueWindowController {
        queueWindowController.attach(player(context), MethodChannelQueuePageProvider(methodChannel))
        return queueWindowController
    }

    /**
     * Establishes a new query-backed queue context — see
     * [QueueWindowController.setContext]. [items] is only the INITIAL
     * window (a small slice around [startIndex] of a possibly much
     * larger logical result set), not the complete queue; more is
     * fetched on demand via the [QueuePageProvider] passed to
     * [ensureQueueController].
     */
    @Synchronized
    fun setQueueContext(
        context: Context,
        contextId: String,
        queueGeneration: Long,
        queueGenerationEpoch: String,
        libraryGeneration: Long,
        totalCount: Int,
        startIndex: Int,
        window: List<Pair<Long, String>>,
        windowStartIndex: Int,
        startPositionMs: Long,
        autoPlay: Boolean = true
    ): Boolean {
        player(context) // ensure created
        return queueWindowController.setContext(
            contextId,
            queueGeneration,
            queueGenerationEpoch,
            libraryGeneration,
            totalCount,
            startIndex,
            window,
            windowStartIndex,
            startPositionMs,
            autoPlay,
        )
    }

    /** See [QueueWindowController.removeItems] — FIX #2 deletion handling. */
    @Synchronized
    fun removeQueueItems(ids: Set<String>) {
        queueWindowController.removeItems(ids)
    }

    @Synchronized
    fun refreshQueueAfterLibraryChange() {
        queueWindowController.refreshAfterLibraryChange()
    }

    @Synchronized
    fun currentQueueContextId(): String? = queueWindowController.currentContextId()

    @Synchronized
    fun clearQueueContextIfMatches(contextId: String): Boolean =
        queueWindowController.clearContextIfMatches(contextId)

    /** Executes an immediate player/session operation while release is excluded. */
    @Synchronized
    fun <T> withCurrentPlayer(block: (ExoPlayer) -> T): T {
        val p = _player ?: throw IllegalStateException("Player is not available")
        return block(p)
    }

    /** Returns true only while [candidate] is still the process-wide live player. */
    @Synchronized
    fun isCurrentPlayer(candidate: ExoPlayer): Boolean = _player === candidate

    /** Runs a session-bound EQ mutation only while this exact player remains live. */
    @Synchronized
    fun <T> withCurrentPlayerSession(candidate: ExoPlayer, block: (ExoPlayer, Int) -> T): T? {
        if (_player !== candidate) return null
        val sessionId = candidate.audioSessionId
        if (sessionId == C.AUDIO_SESSION_ID_UNSET) return null
        return block(candidate, sessionId)
    }

    @Synchronized
    fun reattachQueueProvider(channel: MethodChannel) {
        val existing = _player ?: return
        headlessQueueRuntime?.destroy()
        headlessQueueRuntime = null
        queueWindowController.attach(existing, MethodChannelQueuePageProvider(channel))
    }

    /**
     * Switches logical queue paging to a headless Dart engine before the
     * foreground Flutter engine is destroyed. The native player/window stay
     * alive, while the query-backed provider is recreated against the same
     * persisted Isar queue descriptor.
     */
    @Synchronized
    fun ensureHeadlessQueueProvider(context: Context) {
        if (_player == null || queueWindowController.currentContextId() == null) return
        if (headlessQueueRuntime != null) return
        val runtime = HeadlessFlutterQueueRuntime(context.applicationContext)
        headlessQueueRuntime = runtime
        queueWindowController.attach(player(context), runtime)
    }

    @Synchronized
    fun play(context: Context) {
        player(context).playWhenReady = true
    }

    @Synchronized
    fun pause(context: Context) {
        player(context).playWhenReady = false
    }

    @Synchronized
    fun togglePlayPause(context: Context) {
        val p = player(context)
        p.playWhenReady = !p.playWhenReady
    }

    @Synchronized
    fun seekTo(context: Context, positionMs: Long) {
        // Admit the external seek synchronously. The listener callback that
        // ExoPlayer emits later is too late to invalidate an already-running
        // async queue navigation request.
        queueWindowController.markExternalTransportCommand()
        player(context).seekTo(positionMs)
    }

    /**
     * Suspend: may need to await one queue-page fetch if the logical
     * "next" track isn't in the currently loaded window yet — see
     * [QueueWindowController.skipNext].
     */
    suspend fun skipNext(context: Context): Boolean {
        player(context) // ensure created
        return queueWindowController.skipNext()
    }

    /** Suspend counterpart of [skipNext] — see [QueueWindowController.skipPrevious]. */
    suspend fun skipPrevious(context: Context): Boolean {
        player(context) // ensure created
        return queueWindowController.skipPrevious()
    }

    /**
     * Handles a MediaSession NEXT request. The legacy callback API is
     * synchronous and is invoked on ExoPlayer's application looper, so it
     * cannot truthfully wait for a Dart-backed page fetch without blocking
     * the same looper the fetch needs.
     *
     * If the next item is already physically loaded, completion is immediate
     * and RESULT_SUCCESS is returned. At a logical-window edge, the operation
     * is queued asynchronously and RESULT_INFO_SKIPPED is returned instead of
     * falsely claiming that navigation has already completed. Failures are
     * swallowed at the coroutine boundary so a transient Dart/provider error
     * cannot crash the playback service.
     *
     * null means there is no logical queue and the caller may delegate to the
     * normal Media3 player behavior.
     */
    fun dispatchMediaSessionSkipNext(): Int? {
        synchronized(this) {
            if (queueWindowController.currentContextId() == null) return null
            val p = _player ?: return SessionResult.RESULT_ERROR_INVALID_STATE
            if (p.hasNextMediaItem() && queueWindowController.isWindowLibraryGenerationCurrent()) {
                queueWindowController.markExternalTransportCommand()
                p.seekToNextMediaItem()
                return SessionResult.RESULT_SUCCESS
            }
            if (mediaSessionSkipNextJob?.isActive == true) {
                // Queue this intent instead of collapsing every repeated NEXT
                // command past the first into "at most one more" while a
                // page is loading — see [startSkipNextJob], which drains
                // these one at a time, in order, as each run completes.
                // Intents beyond MAX_PENDING_TRANSPORT_INTENTS are dropped;
                // this is a deliberate resource bound, not a lossless queue.
                if (mediaSessionSkipNextPendingCount < MAX_PENDING_TRANSPORT_INTENTS) {
                    mediaSessionSkipNextPendingCount++
                }
                return SessionResult.RESULT_INFO_SKIPPED
            }
            startSkipNextJob()
            return SessionResult.RESULT_INFO_SKIPPED
        }
    }

    /**
     * Starts one [QueueWindowController.skipNext] run and registers it in
     * [mediaSessionSkipNextJob]. Must be called while holding the
     * [PlayerHolder] monitor (both call sites already do). On completion,
     * if further NEXT intents queued up in [mediaSessionSkipNextPendingCount]
     * while this run was in flight, it drains exactly one of them by
     * recursively starting the next run — so a burst of up to
     * `1 + MAX_PENDING_TRANSPORT_INTENTS` rapid presses produces that many
     * navigations in order. Any presses beyond that bound are dropped at
     * admission (see [dispatchMediaSessionSkipNext]), not queued here.
     */
    private fun startSkipNextJob() {
        val job = queueScope.launch(start = CoroutineStart.LAZY) {
            try {
                runCatching { queueWindowController.skipNext() }
                    .onFailure { /* Async transport failure is contained. */ }
            } finally {
                synchronized(this@PlayerHolder) {
                    if (mediaSessionSkipNextJob === this.coroutineContext[kotlinx.coroutines.Job]) {
                        mediaSessionSkipNextJob = null
                        if (mediaSessionSkipNextPendingCount > 0) {
                            mediaSessionSkipNextPendingCount--
                            startSkipNextJob()
                        }
                    }
                }
            }
        }
        mediaSessionSkipNextJob = job
        job.start()
    }

    fun dispatchMediaSessionSkipPrevious(): Int? {
        synchronized(this) {
            if (queueWindowController.currentContextId() == null) return null
            val p = _player ?: return SessionResult.RESULT_ERROR_INVALID_STATE
            if (p.currentPosition > 3000L) {
                queueWindowController.markExternalTransportCommand()
                p.seekTo(0)
                return SessionResult.RESULT_SUCCESS
            }
            if (p.hasPreviousMediaItem() && queueWindowController.isWindowLibraryGenerationCurrent()) {
                queueWindowController.markExternalTransportCommand()
                p.seekToPreviousMediaItem()
                return SessionResult.RESULT_SUCCESS
            }
            if (mediaSessionSkipPreviousJob?.isActive == true) {
                // Queue this intent instead of collapsing every repeated
                // PREVIOUS command past the first into "at most one more"
                // while a page is loading — see [startSkipPreviousJob],
                // which drains these one at a time, in order, as each run
                // completes. Intents beyond MAX_PENDING_TRANSPORT_INTENTS
                // are dropped; this is a deliberate resource bound, not a
                // lossless queue.
                if (mediaSessionSkipPreviousPendingCount < MAX_PENDING_TRANSPORT_INTENTS) {
                    mediaSessionSkipPreviousPendingCount++
                }
                return SessionResult.RESULT_INFO_SKIPPED
            }
            startSkipPreviousJob()
            return SessionResult.RESULT_INFO_SKIPPED
        }
    }

    /** PREVIOUS counterpart of [startSkipNextJob]; see its doc comment. */
    private fun startSkipPreviousJob() {
        val job = queueScope.launch(start = CoroutineStart.LAZY) {
            try {
                runCatching { queueWindowController.skipPrevious() }
                    .onFailure { /* Async transport failure is contained. */ }
            } finally {
                synchronized(this@PlayerHolder) {
                    if (mediaSessionSkipPreviousJob === this.coroutineContext[kotlinx.coroutines.Job]) {
                        mediaSessionSkipPreviousJob = null
                        if (mediaSessionSkipPreviousPendingCount > 0) {
                            mediaSessionSkipPreviousPendingCount--
                            startSkipPreviousJob()
                        }
                    }
                }
            }
        }
        mediaSessionSkipPreviousJob = job
        job.start()
    }

    /** Safe even before any player exists — returns null rather than crashing. */
    fun currentTrackId(): Long? = currentTrackIdentity()?.second

    /** Returns the volume + MediaStore ID encoded in MediaItem.mediaId. */
    fun currentTrackVolume(): String? = currentTrackIdentity()?.first

    private fun currentTrackIdentity(): Pair<String, Long>? {
        val key = peek()?.currentMediaItem?.mediaId ?: return null
        val separator = key.lastIndexOf(':')
        if (separator <= 0 || separator == key.lastIndex) return null
        val volume = key.substring(0, separator)
        val id = key.substring(separator + 1).toLongOrNull() ?: return null
        return volume to id
    }

    fun setLibraryGeneration(generation: Long) {
        synchronized(this) { queueWindowController.setLibraryGeneration(generation) }
    }

    fun clearLibraryGeneration() {
        synchronized(this) { queueWindowController.clearLibraryGeneration() }
    }

    fun release() {
        // Serialize the ENTIRE teardown with player(context)/setQueueContext.
        // Previously releaseContext() happened before taking this object's
        // monitor. Another entry point could therefore create/attach a new
        // player in that gap, only for the old release() to immediately
        // release that fresh player. Keep queue state teardown and player
        // destruction in one critical section so no new player can slip
        // between them.
        synchronized(this) {
            mediaSessionSkipNextJob?.cancel()
            mediaSessionSkipNextJob = null
            mediaSessionSkipNextPendingCount = 0
            mediaSessionSkipPreviousJob?.cancel()
            mediaSessionSkipPreviousJob = null
            mediaSessionSkipPreviousPendingCount = 0
            // Tear down the queue controller before releasing the player —
            // a fetch that outlives release() must never apply to a new
            // ExoPlayer instance.
            queueWindowController.releaseContext()
            headlessQueueRuntime?.destroy()
            headlessQueueRuntime = null
            _player?.release()
            _player = null
            // Effects are bound to the (now-dead) audio session id — never
            // let them outlive the player that created that session.
            EqualizerController.release()
        }
    }
}
