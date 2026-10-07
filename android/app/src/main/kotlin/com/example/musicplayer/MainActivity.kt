package com.example.musicplayer

import android.content.Intent
import androidx.activity.result.contract.ActivityResultContracts
import com.example.musicplayer.channels.PLAYER_CHANNEL_NAME
import com.example.musicplayer.channels.PLAYER_EVENT_CHANNEL_NAME
import com.example.musicplayer.channels.PlayerChannel
import com.example.musicplayer.channels.PlayerEventChannel
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    companion object {
        // The SAF picker can outlive an Activity instance during configuration
        // changes. Keep the MethodChannel result at process scope so a new
        // Activity instance can complete the same Dart request when the
        // ActivityResultRegistry restores the picker callback. The result is
        // cleared only when the Flutter engine itself is disposed.
        private var pendingFolderAccessResult: MethodChannel.Result? = null
    }

    // FIX #5: SAF directory-tree picker for the sidecar-.lrc fallback
    // on Android 13+ (see SidecarLyricsResolver). Must be registered
    // before the Activity reaches STARTED, so it's a field here rather
    // than created on demand inside the MethodChannel handler.
    private val openLyricsFolder =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { treeUri ->
            val pending = pendingFolderAccessResult
            pendingFolderAccessResult = null
            if (treeUri == null) {
                pending?.success(false)
            } else {
                try {
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
                pending?.success(true)
            } catch (e: SecurityException) {
                pending?.error("SAF_PERMISSION_FAILED", e.message, null)
                } catch (e: Exception) {
                    pending?.error("SAF_PERMISSION_FAILED", e.message, null)
                }
            }
        }

    private var playerChannel: PlayerChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val playerMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLAYER_CHANNEL_NAME
        )
        val channelHandler = PlayerChannel(applicationContext, playerMethodChannel) { result ->
                // Only one folder-access request can be pending at a
                // time — matches there being a single Equalizer/Lyrics
                // screen visible at once.
                if (pendingFolderAccessResult != null) {
                    result.error("SAF_REQUEST_ALREADY_PENDING", "A folder access request is already pending", null)
                } else {
                    pendingFolderAccessResult = result
                    try {
                        openLyricsFolder.launch(null)
                    } catch (e: Exception) {
                        pendingFolderAccessResult = null
                        result.error("SAF_LAUNCH_FAILED", e.message, null)
                    }
                }
            }
        playerChannel = channelHandler
        playerMethodChannel.setMethodCallHandler(channelHandler)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLAYER_EVENT_CHANNEL_NAME
        ).setStreamHandler(PlayerEventChannel())
    }

    override fun onDestroy() {
        // Do not fail the pending SAF result here. A configuration change can
        // destroy this Activity while the system picker remains active; the
        // restored ActivityResult callback must be allowed to complete the
        // original Dart request. Engine disposal is the lifecycle boundary at
        // which the pending result is actually orphaned.
        super.onDestroy()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The native player intentionally survives Activity/Flutter-engine
        // teardown for background playback. Before disposing the foreground
        // MethodChannel, move logical queue paging to a headless Dart engine
        // so a large query-backed queue remains refillable at its window edge.
        runCatching { com.example.musicplayer.playback.PlayerHolder.ensureHeadlessQueueProvider(applicationContext) }
        playerChannel?.dispose()
        playerChannel = null
        pendingFolderAccessResult?.error("ENGINE_DISPOSED", "Flutter engine disposed", null)
        pendingFolderAccessResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
