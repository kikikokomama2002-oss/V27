package com.example.musicplayer.playback

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Collections
import java.util.IdentityHashMap

/**
 * Process-wide singleton wrapping `android.media.audiofx.Equalizer` +
 * `BassBoost`, attached to [PlayerHolder]'s ExoPlayer via its
 * `audioSessionId`.
 *
 * FIX #6 — AUDIO SESSION RACE CONDITION:
 *
 * ExoPlayer does not allocate a real `audioSessionId` the instant it's
 * built — it's assigned once the audio track is actually created,
 * which happens during/after `prepare()`. A caller that opens the
 * Equalizer screen immediately after `setQueue()` (before that has
 * happened) previously read `audioSessionId == C.AUDIO_SESSION_ID_UNSET`
 * (0) exactly once and gave up, silently reporting "unsupported".
 *
 * [awaitAttached] fixes this two ways at once:
 *  1. EVENT-DRIVEN: registers an [AnalyticsListener.onAudioSessionIdChanged]
 *     on the player (once, idempotently) so any future session change —
 *     the initial assignment, or a later release/recreate — re-attaches
 *     the effects automatically without anyone having to ask again.
 *  2. BOUNDED RETRY: for the caller that needs an answer *now* (the
 *     Equalizer screen's initial load), also polls with capped
 *     exponential backoff up to [MAX_WAIT_MS] total, racing whichever
 *     of "the listener fired" / "the next poll saw a valid id" comes
 *     first. If neither happens within the budget, resolves to
 *     "unsupported" rather than hanging the UI forever.
 *
 * Only one wait is ever in flight ([waitJob]); starting a new one (a
 * fresh screen open) cancels any previous wait, and [cancelWait] lets
 * the Dart side cancel explicitly when the Equalizer screen is
 * disposed before a session ever became available.
 */
object EqualizerController {

    private const val MAX_WAIT_MS = 4_000L
    private const val INITIAL_BACKOFF_MS = 50L
    private const val MAX_BACKOFF_MS = 500L

    @Volatile private var equalizer: Equalizer? = null
    @Volatile private var bassBoost: BassBoost? = null
    private var attachedSessionId: Int = -1

    // FIX #6.4 — REAPPLYING SETTINGS ACROSS A SESSION CHANGE.
    //
    // `android.media.audiofx.Equalizer`/`BassBoost` are tied to one
    // audioSessionId for their whole lifetime — there's no "move this
    // effect to a new session" API, only release-and-recreate (see
    // `ensureAttached` below). A session change (a track change on some
    // OEM builds, or the player being released/recreated) previously
    // meant the freshly created Equalizer/BassBoost came up with the
    // device's flat/default curve, silently discarding whatever the
    // user had dialed in — the user's bands and bass boost strength
    // only ever lived inside the (now-released) native effect objects,
    // nowhere else.
    //
    // These three fields are the single source of truth for "what the
    // user currently wants", updated by every `set*`/`use*` call below
    // in addition to (not instead of) applying to the live effect, and
    // replayed onto whichever Equalizer/BassBoost instance is currently
    // attached — including a brand new one `ensureAttached` just
    // created for a new session. Defaults (`enabled = true`, an empty
    // band-level map, `bassBoostStrength = 0`) match what a fresh
    // `Equalizer(...).apply { enabled = true }` already looks like, so
    // reapplying them on the very first-ever attach (nothing to
    // "reapply" yet) is a harmless no-op.
    @Volatile private var desiredEnabled: Boolean = true
    private val desiredBandLevels = LinkedHashMap<Int, Short>()
    @Volatile private var desiredBassBoostStrength: Short = 0

    private var listenerBoundTo: ExoPlayer? = null
    private data class PendingWait(
        val resolved: CompletableDeferred<Boolean>,
        var job: Job? = null,
    )

    private val pendingWaits = Collections.synchronizedMap(IdentityHashMap<ExoPlayer, PendingWait>())

    private val controllerScope = CoroutineScope(Dispatchers.Main.immediate)

    private val analyticsListener = object : AnalyticsListener {
        override fun onAudioSessionIdChanged(
            eventTime: AnalyticsListener.EventTime,
            audioSessionId: Int
        ) {
            // Re-attach reactively whenever ExoPlayer reports a new
            // session (first assignment, or a release/recreate cycle).
            ensureAttached(audioSessionId)
        }
    }

    /** Idempotent: safe to call on every screen open. */
    private fun ensureListenerBound(player: ExoPlayer) {
        if (listenerBoundTo === player) return
        listenerBoundTo?.removeAnalyticsListener(analyticsListener)
        player.addAnalyticsListener(analyticsListener)
        listenerBoundTo = player
    }

    /**
     * Ensures effects are attached to a *valid* audio session before
     * returning, waiting (bounded) for ExoPlayer to assign one if
     * necessary. Returns true only when the requested session has a live
     * Equalizer instance; a valid audioSessionId alone is not success.
     */
    suspend fun awaitAttached(player: ExoPlayer): Boolean {
        ensureListenerBound(player)

        if (player.audioSessionId != C.AUDIO_SESSION_ID_UNSET) {
            return ensureAttached(player.audioSessionId)
        }

        lateinit var resolved: CompletableDeferred<Boolean>
        lateinit var pending: PendingWait
        val existingWait = synchronized(pendingWaits) { pendingWaits[player] }
        if (existingWait != null) {
            // Never suspend while holding the monitor. Cancellation/release
            // must be able to acquire this monitor and complete the waiter.
            return existingWait.resolved.await()
        }

        var created = false
        synchronized(pendingWaits) {
            val raced = pendingWaits[player]
            if (raced != null) {
                resolved = raced.resolved
            } else {
                resolved = CompletableDeferred()
                pending = PendingWait(resolved)
                pendingWaits[player] = pending
                created = true
            }
        }
        if (!created) return resolved.await()

        val job = controllerScope.launch {
            try {
                withTimeoutOrNull(MAX_WAIT_MS) {
                    var backoff = INITIAL_BACKOFF_MS
                    while (isActive) {
                        val sessionId = player.audioSessionId
                        if (sessionId != C.AUDIO_SESSION_ID_UNSET) {
                            resolved.complete(ensureAttached(sessionId))
                            return@withTimeoutOrNull
                        }
                        delay(backoff)
                        backoff = (backoff * 2).coerceAtMost(MAX_BACKOFF_MS)
                    }
                }
                if (!resolved.isCompleted) {
                    resolved.complete(
                        player.audioSessionId != C.AUDIO_SESSION_ID_UNSET &&
                            ensureAttached(player.audioSessionId)
                    )
                }
            } finally {
                synchronized(pendingWaits) {
                    val current = pendingWaits[player]
                    if (current?.resolved === resolved) pendingWaits.remove(player)
                }
            }
        }

        synchronized(pendingWaits) {
            val current = pendingWaits[player]
            if (current?.resolved === resolved) {
                current.job = job
            } else {
                // The coroutine completed before publication of its Job field.
                job.cancel()
            }
        }
        return resolved.await()
    }

    /**
     * Cancels an in-flight [awaitAttached] wait — e.g. the Equalizer
     * screen was closed, or [release] is tearing everything down.
     *
     * FIX #eq-cancel: cancelling [waitJob] alone used to leave the
     * original [awaitAttached] caller suspended forever on
     * `resolved.await()`. `job.cancel()` only stops the *retry loop*
     * — a Job cancelled while suspended inside `delay()`/
     * `withTimeoutOrNull` never reaches its own `resolved.complete(...)`
     * call afterwards, so `resolved` (a separate object, not
     * structurally tied to `job`) was never completed and never
     * cancelled either. [pendingResolved] closes that gap: completing
     * it here (a no-op if it's already completed) unblocks that
     * awaiter immediately, so no coroutine is left suspended after
     * disposal.
     */
    fun cancelWait() {
        val waits = synchronized(pendingWaits) {
            val copy = pendingWaits.values.toList()
            pendingWaits.clear()
            copy
        }
        waits.forEach {
            it.job?.cancel()
            it.resolved.complete(false)
        }
    }

    @Synchronized
private fun ensureAttached(audioSessionId: Int): Boolean {
        if (audioSessionId == C.AUDIO_SESSION_ID_UNSET) return false
        if (audioSessionId == attachedSessionId && equalizer != null) return true
        releaseEffects()

        equalizer = try {
            Equalizer(/* priority = */ 0, audioSessionId).apply { enabled = true }
        } catch (e: Exception) {
            // Device/effect not supported — degrade to "unsupported"
            // rather than crashing (see `state()`'s `supported: false`).
            null
        }
        bassBoost = try {
            BassBoost(/* priority = */ 0, audioSessionId).apply { enabled = true }
        } catch (e: Exception) {
            null
        }
        attachedSessionId = audioSessionId

        // FIX #eq-success: attachment succeeds only when the primary
        // Equalizer was actually created. BassBoost is an optional secondary
        // effect and must not turn a failed Equalizer creation into a false
        // success.
        val attached = equalizer != null

        // FIX #6.4: replay whatever the user had set on the previous
        // session's effects (if any) onto this freshly created pair —
        // see the field docs above. Individually try/catch each so an
        // unsupported call (e.g. a band index out of range for a device
        // whose Equalizer happens to expose fewer bands than the last
        // one) can't stop the rest — enabled state and bass boost —
        // from being reapplied too.
        val eq = equalizer
        if (eq != null) {
            try {
                eq.enabled = desiredEnabled
            } catch (e: Exception) {
                // ignore — best-effort reapply
            }
            for ((band, level) in desiredBandLevels) {
                try {
                    eq.setBandLevel(band.toShort(), level)
                } catch (e: Exception) {
                    // ignore — e.g. this device's Equalizer has fewer
                    // bands than the one the setting was captured from
                }
            }
        }
        val bb = bassBoost
        if (bb != null) {
            try {
                bb.enabled = desiredEnabled
                bb.setStrength(desiredBassBoostStrength)
            } catch (e: Exception) {
                // ignore — best-effort reapply
            }
        }
        return attached
    }

    /** Full state for the Equalizer screen: bands, presets, and current levels. */
    @Synchronized
    fun state(audioSessionId: Int): Map<String, Any?> {
        ensureAttached(audioSessionId)
        val eq = equalizer
            ?: return mapOf(
                "supported" to false,
                "bands" to emptyList<Any>(),
                "presets" to emptyList<Any>(),
                "bassBoostSupported" to false
            )

        val range = eq.bandLevelRange // [min, max] in millibels
        val bands = (0 until eq.numberOfBands).map { i ->
            val band = i.toShort()
            mapOf(
                "index" to i,
                "centerFreqHz" to eq.getCenterFreq(band) / 1000,
                "levelMillibel" to eq.getBandLevel(band).toInt(),
                "minMillibel" to range[0].toInt(),
                "maxMillibel" to range[1].toInt()
            )
        }
        val presets = (0 until eq.numberOfPresets).map { i ->
            mapOf("index" to i, "name" to eq.getPresetName(i.toShort()))
        }

        return mapOf(
            "supported" to true,
            "enabled" to eq.enabled,
            "bands" to bands,
            "presets" to presets,
            "bassBoostSupported" to (bassBoost?.strengthSupported ?: false),
            "bassBoostStrength" to (bassBoost?.roundedStrength?.toInt() ?: 0)
        )
    }

    @Synchronized
    fun setBandLevel(audioSessionId: Int, band: Int, levelMillibel: Int): Boolean {
        ensureAttached(audioSessionId)
        val eq = equalizer ?: return false
        if (band !in 0 until eq.numberOfBands) return false
        val range = eq.bandLevelRange
        if (levelMillibel !in range[0].toInt()..range[1].toInt()) return false
        val level = levelMillibel.toShort()
        val previousDesired = desiredBandLevels[band]
        desiredBandLevels[band] = level
        try {
            eq.setBandLevel(band.toShort(), level)
        } catch (_: Exception) {
            // The native mutation is transactional from the caller's point of
            // view: preserve the last known-good desired state if the effect
            // rejects the new value. A failed mutation must not erase a value
            // that will be needed when the audio session is recreated.
            if (previousDesired == null) {
                desiredBandLevels.remove(band)
            } else {
                desiredBandLevels[band] = previousDesired
            }
            return false
        }
        return true
    }

    @Synchronized
    fun usePreset(audioSessionId: Int, preset: Int): Boolean {
        ensureAttached(audioSessionId)
        val eq = equalizer ?: return false
        if (preset !in 0 until eq.numberOfPresets) return false
        try {
            eq.usePreset(preset.toShort())
        } catch (_: Exception) {
            return false
        }
        // FIX #6.4: a preset sets every band at once — capture the
        // resulting levels (not just "preset index N", which wouldn't
        // survive a device swap where preset lists can differ) so a
        // later session change reapplies the same curve.
        desiredBandLevels.clear()
        for (i in 0 until eq.numberOfBands) {
            desiredBandLevels[i] = eq.getBandLevel(i.toShort())
        }
        return true
    }

    @Synchronized
    fun setBassBoostStrength(audioSessionId: Int, strengthPermille: Int): Boolean {
        ensureAttached(audioSessionId)
        val strength = strengthPermille.coerceIn(0, 1000).toShort()
        val bb = bassBoost ?: return false
        if (!bb.strengthSupported) return false
        try {
            bb.setStrength(strength)
        } catch (_: Exception) {
            // Keep the desired value unchanged if this device rejects it.
            return false
        }
        desiredBassBoostStrength = strength
        return true
    }

    @Synchronized
    fun setEnabled(audioSessionId: Int, enabled: Boolean): Boolean {
        ensureAttached(audioSessionId)
        val eq = equalizer ?: return false
        val previousEqEnabled = runCatching { eq.enabled }.getOrDefault(desiredEnabled)
        val previousBassEnabled = runCatching { bassBoost?.enabled }.getOrNull()
        return try {
            eq.enabled = enabled
            try {
                bassBoost?.enabled = enabled
            } catch (_: Exception) {
                // The operation is transactional: restore every effect we may have
                // already changed before reporting failure to the caller.
                runCatching { eq.enabled = previousEqEnabled }
                if (previousBassEnabled != null) {
                    runCatching { bassBoost?.enabled = previousBassEnabled }
                }
                return false
            }
            desiredEnabled = enabled
            true
        } catch (_: Exception) {
            runCatching { eq.enabled = previousEqEnabled }
            if (previousBassEnabled != null) {
                runCatching { bassBoost?.enabled = previousBassEnabled }
            }
            false
        }
    }

    @Synchronized
    private fun releaseEffects() {
        equalizer?.release()
        equalizer = null
        bassBoost?.release()
        bassBoost = null
        attachedSessionId = -1
    }

    /** Called from [PlayerHolder.release] so effects never outlive their session. */
    @Synchronized
    fun release() {
        cancelWait()
        releaseEffects()
        listenerBoundTo?.removeAnalyticsListener(analyticsListener)
        listenerBoundTo = null
    }
}
