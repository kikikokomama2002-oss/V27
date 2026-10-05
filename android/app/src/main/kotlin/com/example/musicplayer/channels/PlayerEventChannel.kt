package com.example.musicplayer.channels

import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.example.musicplayer.playback.PlayerHolder
import io.flutter.plugin.common.EventChannel

const val PLAYER_EVENT_CHANNEL_NAME = "com.example.musicplayer/player_events"

/**
 * Streams playback state (isPlaying, position, duration, currentTrackId)
 * to Dart so the Now Playing screen / mini-player can react in real
 * time without polling via MethodChannel calls.
 *
 * SAFETY NOTE: `onListen` can fire the moment the Flutter engine attaches
 * — potentially before the user has ever pressed play. This class never
 * calls `PlayerHolder.player(context)`, which would force-create an
 * ExoPlayer (and its audio focus / notification machinery) just because
 * something is listening for state. Instead it only ever uses
 * `PlayerHolder.peek()`, a non-creating accessor that returns null if no
 * player exists yet — so listening is always a no-op until playback
 * actually starts elsewhere (a MethodChannel `setQueue` call or the
 * foreground service). Since no Context is needed to merely peek/observe,
 * this class doesn't take one.
 */
class PlayerEventChannel : EventChannel.StreamHandler {

    private var eventSink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())
    private var positionTicker: Runnable? = null
    private var attachedPlayer: ExoPlayer? = null
    private var eventGeneration = 0L

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            emitState()
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            emitState()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            emitState()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventGeneration++
        eventSink = events

        // Non-creating peek: if a player already exists (playback started
        // before this listener attached), hook it up now. If not, leave
        // attachedPlayer null — emitState() already reports a safe "nothing
        // loaded" state in that case, and the ticker below will attach the
        // listener retroactively the moment a player does get created (or
        // re-created).
        attachPlayerIfAvailable()

        // Position doesn't fire its own callback in ExoPlayer, so poll it
        // on a short interval only while something is listening. This
        // also doubles as the mechanism that notices a player being
        // created (or re-created) later, without ever forcing creation
        // itself.
        positionTicker = object : Runnable {
            override fun run() {
                attachPlayerIfAvailable()
                emitState()
                handler.postDelayed(this, 500)
            }
        }
        handler.post(positionTicker!!)
    }

    override fun onCancel(arguments: Any?) {
        eventGeneration++
        attachedPlayer?.removeListener(playerListener)
        attachedPlayer = null
        positionTicker?.let { handler.removeCallbacks(it) }
        positionTicker = null
        eventSink = null
    }

    /**
     * Safe peek/null-check — attaches the listener to whichever player
     * PlayerHolder currently holds, if any.
     *
     * Compares against [attachedPlayer] by identity rather than only
     * checking for null: PlayerHolder.release() (e.g. foreground service
     * torn down) followed by a fresh PlayerHolder.player(context) call
     * (e.g. the next setQueueContext) produces a NEW ExoPlayer instance while
     * this class is still listening. A null-only check would leave
     * [playerListener] attached to the old, released instance forever —
     * silently missing every event from the new one. Re-checking on every
     * tick and swapping the listener over whenever the instance changes
     * keeps this class correct across any number of player
     * release/recreate cycles, not just the very first creation.
     */
    private fun attachPlayerIfAvailable() {
        val player = PlayerHolder.peek()
        if (player == null) {
            attachedPlayer?.removeListener(playerListener)
            attachedPlayer = null
            return
        }
        if (player === attachedPlayer) return
        attachedPlayer?.removeListener(playerListener)
        attachedPlayer = player
        player.addListener(playerListener)
    }

    private fun emitState() {
        // Use peek() here (never forces creation): if the player was
        // released (e.g. service torn down) between ticks, emit a safe
        // "nothing loaded" state instead of resurrecting a new player
        // just to report on it.
        val player = PlayerHolder.peek()
        val state = if (player == null) {
            mapOf(
                "isPlaying" to false,
                "positionMs" to 0L,
                "durationMs" to 0L,
                "currentTrackId" to null,
                "currentTrackVolume" to null
            )
        } else {
            // Take the identity from the same ExoPlayer instance/snapshot as
            // the playback properties. Calling PlayerHolder's two helpers
            // independently could observe a player replacement between calls
            // and emit a mixed A/B state.
            val identity = player.currentMediaItem?.mediaId
            val separator = identity?.lastIndexOf(':') ?: -1
            val volume = if (separator > 0) identity!!.substring(0, separator) else null
            val trackId = if (separator > 0) identity!!.substring(separator + 1).toLongOrNull() else null
            mapOf(
                "isPlaying" to player.isPlaying,
                "positionMs" to player.currentPosition,
                "durationMs" to (if (player.duration > 0) player.duration else 0L),
                "currentTrackId" to trackId,
                "currentTrackVolume" to volume
            )
        }
        val generation = eventGeneration
        val sourcePlayer = player
        handler.post {
            if (generation != eventGeneration) return@post
            // A snapshot captured from player A must never be delivered after
            // PlayerHolder has released A or replaced it with player B.
            // This closes the queued-handler race without relying on the next
            // 500 ms ticker to correct the UI.
            if (PlayerHolder.peek() !== sourcePlayer) return@post
            eventSink?.success(state)
        }
    }
}
