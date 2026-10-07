package com.example.musicplayer.playback

import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** One page of a [QueueSpec]'s logical result set, resolved by Dart. */
data class QueuePageResult(
    val items: List<Pair<Long, String>>, // (mediaStoreId, contentUri)
    val totalCount: Int,
    val startIndex: Int,
    val libraryGeneration: Long
)

/**
 * FIX #2 — resolves additional pages of the active query-backed queue
 * on demand. The Dart side owns the actual Isar query (see
 * `QueueSpec`/`PlaybackController` on the Dart side) — native only
 * knows "give me tracks [offset, offset+limit) of whatever query is
 * currently active", never the query itself. This keeps native
 * agnostic to what "all tracks" / "a search" / "one album" even mean.
 */
interface QueuePageProvider {
    suspend fun requestPage(contextId: String, offset: Int, limit: Int): QueuePageResult?
    suspend fun requestPageAroundIdentity(
        contextId: String,
        volume: String,
        mediaStoreId: Long,
        before: Int,
        after: Int,
    ): QueuePageResult?
}

/**
 * Calls back into Dart via `MethodChannel.invokeMethod` — the
 * Flutter platform channel is bidirectional, but invoking FROM native
 * TO Dart, and getting a result back, must happen on the main/platform
 * thread and is callback-based, not suspend-based; this wraps that in
 * [suspendCancellableCoroutine] so the rest of the queue controller can
 * simply `await` it like any other suspend call.
 */
class MethodChannelQueuePageProvider(
    private val methodChannel: MethodChannel
) : QueuePageProvider {

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * FIX #4 — every `requestQueuePage` call gets its own id so a
     * cancellation notice (see `invokeOnCancellation` below) always
     * names exactly the one request it belongs to, never a shared slot
     * a later, unrelated request could also match.
     */
    private val nextRequestId = AtomicLong(0)

    override suspend fun requestPage(
        contextId: String,
        offset: Int,
        limit: Int
    ): QueuePageResult? = suspendCancellableCoroutine { cont ->
        val requestId = nextRequestId.incrementAndGet()
        val args = mapOf(
            "contextId" to contextId,
            "offset" to offset,
            "limit" to limit,
            "requestId" to requestId
        )
        val invoke = {
            // The Runnable below may run after a hop to the main thread
            // (see the post() call at the bottom of this block) — if
            // the caller was cancelled while it was queued, don't
            // bother making the round trip at all.
            if (cont.isActive) {
                methodChannel.invokeMethod(
                    "requestQueuePage",
                    args,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            // A no-op (not an error) if `cont` was
                            // cancelled while Dart was resolving this —
                            // `resume` on an inactive continuation is
                            // safely ignored by kotlinx.coroutines, but
                            // the explicit check avoids doing the
                            // `parse()` work for a result nobody reads.
                            if (cont.isActive) cont.resume(parse(result, offset, limit))
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            if (cont.isActive) cont.resume(null)
                        }

                        override fun notImplemented() {
                            if (cont.isActive) cont.resume(null)
                        }
                    }
                )
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) invoke() else mainHandler.post(invoke)

        // FIX #4 — LIFECYCLE-AWARE CANCELLATION.
        //
        // When the coroutine awaiting this call is cancelled — e.g.
        // `QueueWindowController` cancels `forwardFetchJob`/
        // `backwardFetchJob` because the queue context changed
        // (`setContext`), or the player is torn down
        // (`QueueWindowController.releaseContext`, called from
        // `PlayerHolder.release`) — this fires. The platform channel
        // has no built-in way to abort an in-flight `invokeMethod`
        // call, so this is the smallest safe mechanism available: a
        // fire-and-forget companion message carrying the same
        // [requestId], which `PlaybackController._handleNativeCall` (on
        // the Dart side) uses to skip doing further pointless work for
        // a result nothing will ever read, instead of only discovering
        // that after already finishing it.
        cont.invokeOnCancellation {
            val cancelArgs = mapOf("requestId" to requestId)
            val cancel = { methodChannel.invokeMethod("cancelQueuePage", cancelArgs) }
            if (Looper.myLooper() == Looper.getMainLooper()) cancel() else mainHandler.post(cancel)
        }
    }

    override suspend fun requestPageAroundIdentity(
        contextId: String,
        volume: String,
        mediaStoreId: Long,
        before: Int,
        after: Int,
    ): QueuePageResult? = suspendCancellableCoroutine { cont ->
        val requestId = nextRequestId.incrementAndGet()
        val args = mapOf(
            "contextId" to contextId,
            "volume" to volume,
            "id" to mediaStoreId,
            "before" to before,
            "after" to after,
            "requestId" to requestId,
        )
        val invoke = {
            if (cont.isActive) {
                methodChannel.invokeMethod(
                    "requestQueuePageAround", args,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (cont.isActive) cont.resume(parse(result, null, before + after + 1))
                        }
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                            if (cont.isActive) cont.resume(null)
                        }
                        override fun notImplemented() {
                            if (cont.isActive) cont.resume(null) { _, _, _ -> }
                        }
                    }
                )
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) invoke() else mainHandler.post(invoke)
        cont.invokeOnCancellation {
            val cancel = { methodChannel.invokeMethod("cancelQueuePage", mapOf("requestId" to requestId)) }
            if (Looper.myLooper() == Looper.getMainLooper()) cancel() else mainHandler.post(cancel)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun parse(result: Any?, expectedStart: Int?, expectedLimit: Int?): QueuePageResult? {
        val map = result as? Map<String, Any?> ?: return null
        // Dart uses an explicit indeterminate status when it exhausts its
        // bounded snapshot retries. Never parse that as an authoritative
        // empty page: native callers must keep their existing window and
        // retry/rebase later rather than clearing playback.
        if (map["status"] == "indeterminate") return null
        val rawItems = map["items"] as? List<Map<String, Any?>> ?: return null
        val totalCount = (map["totalCount"] as? Number)?.toInt() ?: return null
        val startIndex = (map["startIndex"] as? Number)?.toInt() ?: return null
        val libraryGeneration = (map["libraryGeneration"] as? Number)?.toLong() ?: return null
        if (totalCount < 0 || startIndex < 0 || libraryGeneration < 0) return null
        if (expectedStart != null && startIndex != expectedStart) return null
        if (expectedLimit != null && rawItems.size > expectedLimit.coerceAtLeast(0)) return null
        if (rawItems.isEmpty()) {
            // An empty page is valid when the requested logical offset is at
            // or beyond the current end after a concurrent shrink. The
            // caller will rebase/re-resolve rather than treating this as a
            // malformed response.
            if (startIndex > totalCount) return null
            return QueuePageResult(emptyList(), totalCount, startIndex, libraryGeneration)
        }
        if (startIndex.toLong() + rawItems.size > totalCount.toLong()) return null

        val items = ArrayList<Pair<Long, String>>(rawItems.size)
        val identities = HashSet<String>(rawItems.size)
        for (item in rawItems) {
            val id = (item["id"] as? Number)?.toLong() ?: return null
            if (id <= 0L) return null
            val contentUri = item["contentUri"] as? String ?: return null
            if (contentUri.isBlank()) return null
            val declaredVolume = item["volume"] as? String ?: return null
            if (declaredVolume.isBlank()) return null
            val uri = runCatching { Uri.parse(contentUri) }.getOrNull() ?: return null
            if (uri.scheme != "content") return null
            val volume = runCatching {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    android.provider.MediaStore.getVolumeName(uri)
                } else {
                    "external_primary"
                }
            }.getOrNull() ?: return null
            val normalizedVolume = if (volume == "external") "external_primary" else volume
            val normalizedDeclaredVolume =
                if (declaredVolume == "external") "external_primary" else declaredVolume
            if (normalizedDeclaredVolume != normalizedVolume) return null
            if (!identities.add("$normalizedVolume:$id")) return null
            items += id to contentUri
        }
        return QueuePageResult(items, totalCount, startIndex, libraryGeneration)
    }
}
