package com.example.musicplayer.playback

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Owns a Flutter engine that has no Activity/UI and exists only to service
 * query-backed queue pages after the foreground engine has been detached.
 *
 * The logical queue is persisted by PlaybackController, so the headless Dart
 * isolate can reconstruct QueueSpec + Isar and answer native page requests.
 */
class HeadlessFlutterQueueRuntime(private val appContext: Context) : QueuePageProvider {
    companion object {
        private const val READY_TIMEOUT_MS = 10_000L
        private const val CHANNEL = "com.example.musicplayer/player"
    }

    private val engine = FlutterEngine(appContext)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
    private val ready = CompletableDeferred<Unit>()
    private val nativePlayerChannel = com.example.musicplayer.channels.PlayerChannel(appContext, channel) { }
    private val delegate = MethodChannelQueuePageProvider(channel)

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "headlessReady") {
                ready.complete(Unit)
                result.success(true)
            } else {
                nativePlayerChannel.onMethodCall(call, result)
            }
        }
        val entrypoint = DartExecutor.DartEntrypoint(
            appContext.assets,
            "flutter_assets",
            "headlessMain"
        )
        engine.dartExecutor.executeDartEntrypoint(entrypoint)
    }

    private suspend fun awaitReady(): Boolean = withTimeoutOrNull(READY_TIMEOUT_MS) {
        ready.await()
        true
    } ?: false

    override suspend fun requestPage(contextId: String, offset: Int, limit: Int): QueuePageResult? {
        if (!awaitReady()) return null
        return delegate.requestPage(contextId, offset, limit)
    }

    override suspend fun requestPageAroundIdentity(
        contextId: String,
        volume: String,
        mediaStoreId: Long,
        before: Int,
        after: Int,
    ): QueuePageResult? {
        if (!awaitReady()) return null
        return delegate.requestPageAroundIdentity(contextId, volume, mediaStoreId, before, after)
    }

    fun destroy() {
        if (!ready.isCompleted) ready.cancel()
        channel.setMethodCallHandler(null)
        nativePlayerChannel.dispose()
        engine.destroy()
    }
}
