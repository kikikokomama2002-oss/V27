package com.example.musicplayer.scanner

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.provider.MediaStore
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.util.Size
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * Loads embedded album artwork for a track's `content://` URI — no
 * placeholder art, no raw file paths.
 *
 * API 29+: uses `ContentResolver.loadThumbnail`, MediaStore's own
 * thumbnail pipeline. It decodes (and caches, via MediaProvider's own
 * thumbnail store) a bitmap downsampled to roughly the requested size,
 * preserving aspect ratio, without the caller ever touching the
 * full-resolution embedded image.
 *
 * API < 29 uses the platform audio-thumbnail provider instead of
 * `MediaMetadataRetriever.embeddedPicture`, avoiding the unbounded embedded-
 * frame allocation path while still supporting the app's declared minSdk.
 *
 * The provider thumbnail call uses a bounded isolated provider thread. Timed-out
 * workers are quarantined rather than returned to a reusable pool. Bitmap
 * decode/PNG encoding stays on the separate bounded decode pool.
 *
 * Shared requests are reference-counted by consumer id. A consumer can
 * release its own interest without cancelling another consumer's shared
 * operation. The underlying Deferred is cancelled only after the last
 * consumer releases it.
 */
object AlbumArtLoader {

    class AdmissionException : IllegalStateException("ARTWORK_RESOURCE_BUSY")
    class ResourceException(message: String, cause: Throwable? = null) : IllegalStateException(message, cause)
    class ProviderException(message: String, cause: Throwable? = null) : IllegalStateException(message, cause)

    private const val ART_LOAD_TIMEOUT_MS = 2_500L
    private const val BLOCKING_PROVIDER_POOL_SIZE = 1
    private const val DECODE_POOL_SIZE = 3
    private const val MAX_IN_FLIGHT_ART_REQUESTS = 128
    private const val MAX_CONSUMERS_PER_REQUEST = 256
    private const val MAX_DECODED_ART_PIXELS = 4L * 1024L * 1024L
    private const val MAX_DECODED_ART_DIMENSION = 2048

    private val decodeDispatcher =
        Executors.newFixedThreadPool(DECODE_POOL_SIZE).asCoroutineDispatcher()

    /**
     * Existing bounded native/blocking pool for ContentResolver thumbnail
     * operations. Keeping it bounded prevents
     * pathological URIs from consuming an unbounded number of threads.
     */
    private val requestScope =
        CoroutineScope(SupervisorJob() + decodeDispatcher)

    // Provider/native calls cannot always be hard-killed. Run each blocking
    // operation on its own daemon thread so one hung provider cannot pin a
    // reusable worker pool. Timed-out threads are quarantined; a small hard
    // cap prevents unbounded thread leakage if a provider ignores interrupts
    // forever.
    private const val MAX_QUARANTINED_WORKERS = 4
    private val quarantineLock = Any()
    private var quarantinedWorkers = 0
    // Bound decoded-bitmap memory independently of the request/retriever
    // pools. A 2048px RGBA bitmap is ~16 MiB before compression; keeping at
    // most two decode operations active prevents a burst of large artwork
    // requests from multiplying that allocation without bound.
    private val decodeMemorySemaphore = Semaphore(2)
    private val blockingOperationSemaphore = Semaphore(BLOCKING_PROVIDER_POOL_SIZE)

    private fun key(contentUri: Uri, sizePx: Int, version: Long) = "$contentUri:$sizePx:$version"

    private class SharedRequest(
        val deferred: Deferred<ByteArray?>,
        val consumers: MutableSet<String> = HashSet()
    )

    private val inFlight = ConcurrentHashMap<String, SharedRequest>()
    private val requestLock = Any()

    /** Returns compressed PNG bytes, or null if the track has no embedded artwork. */
    suspend fun load(
        context: Context,
        contentUri: Uri,
        sizePx: Int,
        consumerId: String,
        version: Long,
    ): ByteArray? {
        val safeSizePx = sizePx.coerceIn(32, 2048)
        val requestKey = key(contentUri, safeSizePx, version)
        val shared = acquire(
            requestKey = requestKey,
            consumerId = consumerId
        ) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                loadViaThumbnail(context, contentUri, safeSizePx)?.let { return@acquire it }
            } else {
                loadLegacyAudioThumbnail(context, contentUri, safeSizePx)?.let { return@acquire it }
            }
            null
        } ?: return null

        return try {
            shared.deferred.await()
        } finally {
            release(requestKey, consumerId, shared)
        }
    }

    /**
     * Adds one consumer to the shared request, or creates the request.
     *
     * The lock covers both lookup and consumer insertion, so subscribe and
     * release cannot race into a negative count or accidentally cancel a
     * request that has just acquired another consumer.
     */
    private fun acquire(
        requestKey: String,
        consumerId: String,
        operation: suspend () -> ByteArray?
    ): SharedRequest? {
        synchronized(requestLock) {
            val existing = inFlight[requestKey]
            if (existing != null && !existing.deferred.isCompleted) {
                // Deduplication must not become an unbounded memory side door:
                // one logical artwork request can otherwise accumulate an
                // arbitrary number of consumer ids even while the global
                // inFlight request-key cap remains at 128. Releasing consumers
                // is independent and idempotent, so a bounded per-request set
                // is sufficient for UI fan-out while keeping adversarial bursts
                // memory-bounded.
                if (existing.consumers.contains(consumerId)) return existing
                if (existing.consumers.size >= MAX_CONSUMERS_PER_REQUEST) {
                    throw AdmissionException()
                }
                existing.consumers.add(consumerId)
                return existing
            }

            if (inFlight.size >= MAX_IN_FLIGHT_ART_REQUESTS) {
                throw AdmissionException()
            }

            lateinit var created: SharedRequest
            val deferred = requestScope.async {
                operation()
            }
            created = SharedRequest(deferred)
            created.consumers.add(consumerId)
            inFlight[requestKey] = created

            deferred.invokeOnCompletion {
                synchronized(requestLock) {
                    if (inFlight[requestKey] === created) {
                        inFlight.remove(requestKey)
                    }
                    // Completion/failure ends the shared operation for every
                    // consumer. Their later finally blocks become harmless
                    // no-ops because the ids are no longer present.
                    created.consumers.clear()
                }
            }

            return created
        }
    }

    /**
     * Releases exactly one consumer's interest.
     *
     * Duplicate release/cancel calls are deliberately idempotent because the
     * consumer id is stored in a Set. The underlying operation is cancelled
     * only when the last active consumer is gone.
     */
    private fun release(
        requestKey: String,
        consumerId: String,
        shared: SharedRequest
    ) {
        var cancelUnderlying = false

        synchronized(requestLock) {
            // A completed request may already have removed its consumers and
            // in-flight entry. That is an expected late release.
            if (!shared.consumers.remove(consumerId)) return

            if (shared.consumers.isEmpty() && inFlight[requestKey] === shared) {
                inFlight.remove(requestKey)
                cancelUnderlying = true
            }
        }

        if (cancelUnderlying) {
            shared.deferred.cancel()
        }
    }

    /**
     * Releases one specific consumer's interest in an in-flight request.
     * It is safe to call this more than once.
     */
    fun cancel(contentUri: Uri, sizePx: Int, consumerId: String, version: Long) {
        val safeSizePx = sizePx.coerceIn(32, 2048)
        val requestKey = key(contentUri, safeSizePx, version)
        val shared = synchronized(requestLock) {
            inFlight[requestKey]
        } ?: return
        release(requestKey, consumerId, shared)
    }

    /**
     * ContentResolver.loadThumbnail() may perform blocking provider/native
     * work. Keep that operation on the bounded blocking/native pool, then
     * return to the decode dispatcher before converting the Bitmap to PNG.
     */
    private suspend fun <T> runBlockingProvider(
        block: () -> T,
        onLateValue: (T) -> Unit = {},
        onCancel: () -> Unit = {},
    ): T? =
        blockingOperationSemaphore.withPermit {
            synchronized(quarantineLock) {
                if (quarantinedWorkers >= MAX_QUARANTINED_WORKERS) {
                    throw AdmissionException()
                }
            }

            suspendCancellableCoroutine { continuation ->
                lateinit var worker: Thread
                val completed = AtomicBoolean(false)
                val cancelled = AtomicBoolean(false)
                val quarantined = AtomicBoolean(false)

                worker = Thread({
                    try {
                        val value = block()
                        completed.set(true)
                        if (cancelled.get()) {
                            try { onLateValue(value) } catch (_: Exception) {}
                        } else {
                            // The cancellation handler for a resumed value is
                            // the ownership hand-off. If the parent is
                            // cancelled after this call but before the
                            // continuation is dispatched, Kotlin invokes this
                            // callback and the Bitmap cannot be leaked.
                            continuation.resume(value) { _ ->
                                try { onLateValue(value) } catch (_: Exception) {}
                            }
                        }
                    } catch (e: Exception) {
                        completed.set(true)
                        if (!cancelled.get() && continuation.isActive) {
                            try {
                                continuation.resumeWith(Result.failure(e))
                            } catch (_: IllegalStateException) {
                                // Cancellation/completion won the race after the
                                // active check. The late failure is intentionally
                                // discarded rather than crashing the provider thread.
                            }
                        }
                    } catch (e: Error) {
                        completed.set(true)
                        if (!cancelled.get() && continuation.isActive) {
                            try {
                                continuation.resumeWith(Result.failure(e))
                            } catch (_: IllegalStateException) {
                                // Same cancellation/completion race as above.
                            }
                        }
                    } finally {
                        if (quarantined.get()) {
                            synchronized(quarantineLock) {
                                quarantinedWorkers = (quarantinedWorkers - 1).coerceAtLeast(0)
                            }
                        }
                    }
                }, "album-art-provider").apply {
                    isDaemon = true
                }

                continuation.invokeOnCancellation {
                    cancelled.set(true)
                    try { onCancel() } catch (_: Exception) {}
                    if (!completed.get()) {
                        synchronized(quarantineLock) {
                            if (quarantined.compareAndSet(false, true)) {
                                quarantinedWorkers++
                            }
                        }
                        worker.interrupt()
                    }
                }
                worker.start()
            }
        }

    private suspend fun loadLegacyAudioThumbnail(
        context: Context,
        contentUri: Uri,
        sizePx: Int,
    ): ByteArray? {
        val bytes = try {
            kotlinx.coroutines.withTimeout(ART_LOAD_TIMEOUT_MS) {
                runBlockingProvider(
                    block = {
                        context.contentResolver.openInputStream(contentUri)?.use { it.readBytes() }
                    },
                )
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw ProviderException("Legacy artwork provider timed out", e)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: ProviderException) {
            throw e
        } catch (e: Exception) {
            throw ProviderException("Legacy artwork provider failed", e)
        } ?: return null

        return try {
            decodeMemorySemaphore.withPermit {
                val bitmap = decodeSampledBitmap(bytes, sizePx) ?: return@withPermit null
                try {
                    if (bitmap.width.toLong() * bitmap.height.toLong() >
                        MAX_DECODED_ART_PIXELS
                    ) {
                        throw ResourceException("Artwork bitmap exceeds memory budget")
                    }
                    val png = bitmap.toPngBytes()
                    if (png.size > 8 * 1024 * 1024) {
                        throw ResourceException("Artwork PNG exceeds encoded-size budget")
                    }
                    png
                } finally {
                    bitmap.recycle()
                }
            }
        } catch (e: OutOfMemoryError) {
            throw ResourceException("Artwork decode exhausted memory", e)
        }
    }

    private suspend fun loadViaThumbnail(
        context: Context,
        contentUri: Uri,
        sizePx: Int
    ): ByteArray? {
        return try {
            val bitmap = try {
                kotlinx.coroutines.withTimeout(ART_LOAD_TIMEOUT_MS) {
                    val cancellationSignal = CancellationSignal()
                    try {
                        runBlockingProvider(
                            block = {
                                context.contentResolver.loadThumbnail(
                                    contentUri,
                                    Size(sizePx, sizePx),
                                    cancellationSignal,
                                )
                            },
                            onLateValue = { it.recycle() },
                            onCancel = { cancellationSignal.cancel() },
                        )
                    } finally {
                        // A completed request has no pending provider work; this
                        // is harmless and closes the cancellation lifecycle.
                        cancellationSignal.cancel()
                    }
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                throw ProviderException("Artwork provider timed out", e)
            } ?: return null

            try {
                decodeMemorySemaphore.withPermit {
                    // loadViaThumbnail is called from requestScope/decodeDispatcher,
                    // so PNG compression remains isolated from the blocking pool.
                    if (bitmap.width.toLong() * bitmap.height.toLong() * 4L > 16L * 1024L * 1024L) {
                        throw ResourceException("Artwork bitmap exceeds memory budget")
                    }
                    val png = bitmap.toPngBytes()
                    if (png.size > 8 * 1024 * 1024) {
                        throw ResourceException("Artwork PNG exceeds encoded-size budget")
                    }
                    png
                }
            } finally {
                // Also executes when cancellation happens while waiting for the
                // semaphore, which is before withPermit invokes its body.
                bitmap.recycle()
            }
        } catch (e: OutOfMemoryError) {
            throw ResourceException("Artwork decode exhausted memory", e)
        } catch (e: CancellationException) {
            throw e
        } catch (e: ResourceException) {
            // Resource exhaustion/rejection is a distinct semantic outcome.
            // Preserve it so PlayerChannel can expose ARTWORK_RESOURCE_UNAVAILABLE
            // instead of downgrading it to provider failure/retry.
            throw e
        } catch (e: ProviderException) {
            throw e
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            throw ProviderException("Artwork provider failed", e)
        }
    }

    /**
     * Decodes [bytes] downsampled to [reqSize]px with an independent pixel
     * and dimension ceiling. The bounds-only pass completes before bitmap
     * allocation, preventing pathological dimensions from requesting a huge
     * bitmap.
     */
    private fun decodeSampledBitmap(bytes: ByteArray, reqSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val width = bounds.outWidth.toLong()
        val height = bounds.outHeight.toLong()
        if (width <= 0L || height <= 0L) return null

        // Choose the sample size from the requested display size AND an
        // independent pixel ceiling. Bounds decoding allocates no bitmap, so
        // these checks happen before the dangerous pixel allocation.
        var sampleSize = 1
        while (true) {
            val sampledWidth = (width + sampleSize - 1L) / sampleSize
            val sampledHeight = (height + sampleSize - 1L) / sampleSize
            val tooLargeForDisplay = sampledWidth > reqSize || sampledHeight > reqSize
            val tooManyPixels = sampledWidth * sampledHeight > MAX_DECODED_ART_PIXELS
            val tooLargeDimension =
                sampledWidth > MAX_DECODED_ART_DIMENSION || sampledHeight > MAX_DECODED_ART_DIMENSION
            if (!tooLargeForDisplay && !tooManyPixels && !tooLargeDimension) break
            if (sampleSize > (1 shl 29)) return null
            sampleSize *= 2
        }

        val decodeOptions = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
        }
        val sampled =
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions) ?: return null

        val oriented = applyExifOrientation(bytes, sampled)
        if (oriented != null && oriented !== sampled) {
            sampled.recycle()
        }
        val source = oriented ?: sampled
        if (source.width <= reqSize && source.height <= reqSize) {
            return source
        }

        val scale = reqSize.toFloat() / maxOf(source.width, source.height)
        val targetWidth = (source.width * scale).toInt().coerceAtLeast(1)
        val targetHeight = (source.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(source, targetWidth, targetHeight, true)
        if (scaled !== source) {
            source.recycle()
        }
        return scaled
    }

    /**
     * The safe thumbnail payload is decoded here; unlike the
     * MediaStore thumbnail pipeline, BitmapFactory does not apply JPEG EXIF
     * orientation automatically. Read only the EXIF orientation tag and
     * apply the corresponding non-destructive matrix to the already-sampled
     * bitmap. No full-resolution second decode is introduced.
     */
    private fun applyExifOrientation(bytes: ByteArray, bitmap: Bitmap): Bitmap? {
        return try {
            val exif = ExifInterface(ByteArrayInputStream(bytes))
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
            if (orientation == ExifInterface.ORIENTATION_NORMAL ||
                orientation == ExifInterface.ORIENTATION_UNDEFINED
            ) {
                null
            } else {
                val matrix = Matrix()
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL ->
                        matrix.setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 ->
                        matrix.setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL ->
                        matrix.setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> {
                        matrix.setRotate(90f)
                        matrix.postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_ROTATE_90 ->
                        matrix.setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> {
                        matrix.setRotate(-90f)
                        matrix.postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_ROTATE_270 ->
                        matrix.setRotate(-90f)
                    else -> return null
                }
                Bitmap.createBitmap(
                    bitmap,
                    0,
                    0,
                    bitmap.width,
                    bitmap.height,
                    matrix,
                    true,
                ).takeUnless { it === bitmap }
            }
        } catch (_: Exception) {
            // Some embedded images have no readable EXIF block. Their
            // decoded pixels are still valid and should pass through.
            null
        }
    }

    private fun Bitmap.toPngBytes(): ByteArray {
        val stream = ByteArrayOutputStream()
        compress(Bitmap.CompressFormat.PNG, 90, stream)
        return stream.toByteArray()
    }
}
