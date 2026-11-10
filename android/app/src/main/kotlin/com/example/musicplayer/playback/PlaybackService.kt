package com.example.musicplayer.playback

import android.app.PendingIntent
import android.content.Intent
import com.example.musicplayer.MainActivity
import android.os.Handler
import android.os.Looper
import androidx.media3.common.ForwardingSimpleBasePlayer
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
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
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {

    companion object {
        @Volatile private var activeService: PlaybackService? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /** Refreshes lock-screen/notification commands when the user changes its setting. */
        @JvmStatic
        fun refreshNotificationCommands() {
            val service = activeService ?: return
            mainHandler.post { service.refreshLogicalQueueState() }
        }
    }

    private lateinit var mediaSession: MediaSession
    private inner class LogicalSessionPlayer(player: Player) :
        ForwardingSimpleBasePlayer(player) {

        override fun getState(): SimpleBasePlayer.State {
            val state = super.getState()
            val hasLogicalNext = PlayerHolder.hasLogicalNext() ?: return state
            val commands = state.availableCommands.buildUpon()

            if (hasLogicalNext) {
                // Media3 1.6.1's DefaultMediaNotificationProvider creates the
                // notification Next action only when one of these standard
                // player commands is actually available to the controller.
                commands.add(Player.COMMAND_SEEK_TO_NEXT)
                commands.add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            } else {
                commands.remove(Player.COMMAND_SEEK_TO_NEXT)
                commands.remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            }

            return state.buildUpon()
                .setAvailableCommands(commands.build())
                .build()
        }

        fun refreshLogicalQueueState() {
            invalidateState()
        }
    }

    private lateinit var sessionPlayer: LogicalSessionPlayer

    override fun onCreate() {
        super.onCreate()
        activeService = this
        // PlayerHolder.player(context) lazily creates the ExoPlayer if it
        // doesn't exist yet, so this is safe regardless of whether a
        // MethodChannel call already created it first.
        val callback = object : MediaSession.Callback {
            override fun onConnect(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
            ): MediaSession.ConnectionResult {
                val base = super.onConnect(session, controller)
                if (!base.isAccepted) return base
                if (session.isMediaNotificationController(controller) &&
                    !PlayerHolder.isLockScreenControlsEnabled(this@PlaybackService)
                ) {
                    return MediaSession.ConnectionResult.accept(
                        base.availableSessionCommands,
                        withoutTransportCommands(base.availablePlayerCommands),
                    )
                }
                return base
            }

            override fun onPostConnect(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
            ) {
                if (session.isMediaNotificationController(controller)) {
                    applyNotificationCommands()
                    triggerNotificationUpdate()
                }
            }

            @Suppress("DEPRECATION")
            override fun onPlayerCommandRequest(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
                playerCommand: Int,
            ): Int {
                val currentPlayer = PlayerHolder.peek()
                val isExternalController = controller.packageName != packageName &&
                    !session.isMediaNotificationController(controller)
                val isStartCommand = playerCommand == Player.COMMAND_PLAY_PAUSE ||
                    playerCommand == Player.COMMAND_PREPARE
                if (isExternalController && isStartCommand && currentPlayer?.playWhenReady != true &&
                    !PlayerHolder.isExternalDeviceStartEnabled(this@PlaybackService)
                ) {
                    return SessionResult.RESULT_ERROR_PERMISSION_DENIED
                }

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
        val sharedPlayer = PlayerHolder.player(this)
        sessionPlayer = LogicalSessionPlayer(sharedPlayer)

        // Re-apply notification commands after Media3 publishes the refreshed state.
        sessionPlayer.addListener(object : Player.Listener {
            override fun onAvailableCommandsChanged(availableCommands: Player.Commands) {
                applyNotificationCommands(availableCommands)
                triggerNotificationUpdate()
            }
        })

        mediaSession = synchronized(PlayerHolder) {
            MediaSession.Builder(this, sessionPlayer)
                .setSessionActivity(
                    PendingIntent.getActivity(
                        this,
                        0,
                        Intent(this, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                        },
                        PendingIntent.FLAG_UPDATE_CURRENT or
                            PendingIntent.FLAG_IMMUTABLE
                    )
                )
                .setCallback(callback)
                .build()
        }

        // Register the session with Media3's notification manager.
        // V27 drives the shared ExoPlayer through MethodChannel rather
        // than relying on a UI MediaController to register this session.
        addSession(mediaSession)
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

    private fun refreshLogicalQueueState() {
        if (!::sessionPlayer.isInitialized) return
        // Recompute the logical NEXT command before refreshing the actual
        // notification. Queue-window changes do not always mutate ExoPlayer's
        // physical timeline, so relying only on its player listeners can leave
        // the system notification displaying stale transport buttons.
        sessionPlayer.refreshLogicalQueueState()
        applyNotificationCommands()
        triggerNotificationUpdate()
    }

    @OptIn(UnstableApi::class)
    private fun applyNotificationCommands(
        playerCommands: Player.Commands = sessionPlayer.availableCommands,
    ) {
        if (!::mediaSession.isInitialized) return
        val notificationController = mediaSession.mediaNotificationControllerInfo ?: return
        val isConnected = mediaSession.connectedControllers.any {
            mediaSession.isMediaNotificationController(it)
        }
        if (!isConnected) return

        val effectiveCommands = if (PlayerHolder.isLockScreenControlsEnabled(this)) {
            playerCommands
        } else {
            withoutTransportCommands(playerCommands)
        }
        // V27 has no custom session commands; the standard Media3 commands
        // remain available while player transport actions are hidden.
        runCatching {
            mediaSession.setAvailableCommands(
                notificationController,
                MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS,
                effectiveCommands,
            )
        }
    }

    private fun withoutTransportCommands(commands: Player.Commands): Player.Commands =
        commands.buildUpon()
            .remove(Player.COMMAND_PLAY_PAUSE)
            .remove(Player.COMMAND_PREPARE)
            .remove(Player.COMMAND_STOP)
            .remove(Player.COMMAND_SEEK_TO_NEXT)
            .remove(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
            .remove(Player.COMMAND_SEEK_TO_PREVIOUS)
            .remove(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
            .remove(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
            .build()

    override fun onDestroy() {
        if (activeService === this) activeService = null
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
