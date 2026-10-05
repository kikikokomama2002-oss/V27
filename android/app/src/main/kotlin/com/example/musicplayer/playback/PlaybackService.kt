package com.example.musicplayer.playback

import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionResult
import androidx.media3.common.Player

/**
 * Foreground service exposing the shared [PlayerHolder] ExoPlayer to the
 * system as a MediaSession — this is what gives us lock-screen controls,
 * the media notification, Bluetooth/headset button support, and Android
 * Auto compatibility for free, and lets ExoPlayer's handleAudioFocus=true
 * automatically duck/pause on calls or other audio.
 *
 * Gapless playback is a property of the queue: the currently loaded
 * window of a query-backed queue is one ExoPlayer playlist (see
 * [PlayerHolder.setQueueContext] / [QueueWindowController]), so track
 * transitions reuse the same decoder pipeline instead of stopping and
 * restarting playback per song — including across a window
 * expansion/trim, which only adds/removes items, never rebuilds the
 * playlist.
 */
class PlaybackService : MediaSessionService() {

    private lateinit var mediaSession: MediaSession

    override fun onCreate() {
        super.onCreate()
        // PlayerHolder.player(context) lazily creates the ExoPlayer if it
        // doesn't exist yet, so this is safe regardless of whether a
        // MethodChannel call already created it first.
        val callback = object : MediaSession.Callback {
            @Suppress("DEPRECATION")
            override fun onPlayerCommandRequest(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
                playerCommand: Int,
            ): Int {
                return when (playerCommand) {
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> {
                        PlayerHolder.dispatchMediaSessionSkipNext()
                            ?: super.onPlayerCommandRequest(session, controller, playerCommand)
                    }
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> {
                        PlayerHolder.dispatchMediaSessionSkipPrevious()
                            ?: super.onPlayerCommandRequest(session, controller, playerCommand)
                    }
                    else -> super.onPlayerCommandRequest(session, controller, playerCommand)
                }
            }
        }
        mediaSession = synchronized(PlayerHolder) {
            MediaSession.Builder(this, PlayerHolder.player(this))
                .setCallback(callback)
                .build()
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession {
        return mediaSession
    }

    /**
     * Only stop the service (and playback) when the task is swiped away
     * AND nothing is actively playing — otherwise keep the foreground
     * service alive so music keeps playing, matching user expectations
     * for a music app.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = PlayerHolder.peek()
        if (player == null || !player.isPlaying || player.mediaItemCount == 0) {
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        // MediaSessionService lifetime is not the same as the Flutter engine
        // or the process-wide PlayerHolder lifetime. Android/Media3 may destroy
        // an idle service while the Flutter controller and its logical queue are
        // still alive. Releasing PlayerHolder here would therefore silently
        // destroy the native queue and leave Dart pointing at an empty player.
        // Keep the shared player alive; a later service instance can attach a
        // new MediaSession to the same ExoPlayer. The process itself remains the
        // ultimate owner of PlayerHolder resources.
        mediaSession.release()
        super.onDestroy()
    }
}
