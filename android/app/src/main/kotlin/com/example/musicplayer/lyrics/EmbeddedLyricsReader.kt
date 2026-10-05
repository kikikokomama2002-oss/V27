package com.example.musicplayer.lyrics

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.Metadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.MetadataRetriever
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.extractor.metadata.id3.BinaryFrame
import androidx.media3.extractor.metadata.id3.CommentFrame
import androidx.media3.extractor.metadata.id3.TextInformationFrame
import androidx.media3.extractor.metadata.vorbis.VorbisComment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import com.google.common.util.concurrent.MoreExecutors
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Reads lyrics embedded directly in an audio file's own metadata tags —
 * ID3 USLT/COMM (MP3), a Vorbis "LYRICS"/"UNSYNCEDLYRICS" comment
 * (FLAC/OGG), or the "©lyr" atom (M4A/AAC) — instead of querying
 * `MediaStore.Files` for a sibling `.lrc` file.
 *
 * WHY THIS REPLACED THE SIDECAR-`.lrc` LOOKUP: on Android 13+,
 * `READ_MEDIA_AUDIO` only grants the app visibility into MediaStore rows
 * for audio files. A `.lrc` file is plain text, not audio, so a
 * `MediaStore.Files` query for it matches zero rows regardless of
 * whether the file exists on disk — the old `findSiblingContentUri`
 * approach silently returned null for every track on API 33+. Reading
 * tags out of the audio file itself sidesteps the problem entirely: the
 * app already has permission to that file's bytes (it's the file being
 * played), and the embedded tag is just more of those same bytes.
 *
 * The returned text is whatever the tagger actually wrote into the
 * frame — plain prose, or a full `.lrc`-formatted block (many taggers
 * stuff synced lyrics into USLT even though ID3 nominally reserves that
 * for SYLT). Callers should run it through `LrcParser.parse` and fall
 * back to a plain-text display if that yields no timed lines.
 */
object EmbeddedLyricsReader {

    /** Temporary metadata/provider failure that must not be cached as
     * authoritative absence of lyrics by the repository. */
    class TransientReadException(message: String, cause: Throwable? = null) :
        IllegalStateException(message, cause)

    /** Readable lyrics exceeded the bounded resource budget. */
    class ResourceException(message: String, cause: Throwable? = null) :
        IllegalStateException(message, cause)

    /** Metadata/provider read failed. This must never be represented as null. */
    class ProviderException(message: String, cause: Throwable? = null) :
        IllegalStateException(message, cause)

    /** Wall-clock budget for extracting metadata from one file. */
    private const val TIMEOUT_MS = 5_000L
    private const val MAX_LYRICS_CHARS = 1_048_576
    private const val MAX_LYRICS_BYTES = 1_048_576

    /**
     * @param contentUri the track's own `content://media/external/audio/...`
     *   URI (never a raw path) — the same one handed to ExoPlayer for
     *   playback.
     * @return the raw lyrics text, or null only when the file was read
     *   successfully and no recognized lyrics tag was present. Read/provider
     *   failures are surfaced as typed exceptions.
     */
    @OptIn(UnstableApi::class)
    suspend fun read(context: Context, contentUri: String): String? =
        withContext(Dispatchers.IO) {
            try {
                val mediaItem = MediaItem.fromUri(Uri.parse(contentUri))
                val future = MetadataRetriever.retrieveMetadata(context, mediaItem)
                val trackGroups = withTimeout(TIMEOUT_MS) {
                    suspendCancellableCoroutine<TrackGroupArray> { continuation ->
                    future.addListener(
                        {
                            try {
                                continuation.resume(future.get())
                            } catch (e: Exception) {
                                if (e is CancellationException) {
                                    continuation.cancel(e)
                                } else {
                                    continuation.resumeWithException(e)
                                }
                            }
                        },
                        MoreExecutors.directExecutor(),
                    )
                        continuation.invokeOnCancellation {
                            future.cancel(true)
                        }
                    }
                }
                extractLyrics(trackGroups)
            } catch (e: TimeoutCancellationException) {
                // A metadata timeout is transient. The caller may still try
                // sidecar lyrics, but if that also fails/returns nothing this
                // outcome must not become an authoritative negative cache.
                throw TransientReadException("Embedded lyrics metadata timed out", e)
            } catch (e: CancellationException) {
                throw e
            } catch (e: ResourceException) {
                throw e
            } catch (e: Exception) {
                // A failed metadata/provider read is not evidence that the file
                // has no lyrics. Preserve the failure so PlayerChannel can try
                // the sidecar and, if that is also absent, return an error
                // rather than poisoning the negative lyrics cache.
                throw ProviderException("Embedded lyrics provider failed", e)
            }
        }

    private fun extractLyrics(trackGroups: TrackGroupArray): String? {
        // Lowest-priority match: a generic COMM frame whose description
        // hints it's actually being used to carry lyrics. Only returned
        // if nothing more specific (USLT, a Vorbis LYRICS comment, or an
        // MP4 lyrics atom) was found anywhere in the file's metadata.
        var commFallback: String? = null

        for (i in 0 until trackGroups.length) {
            val group = trackGroups[i]
            for (j in 0 until group.length) {
                val metadata: Metadata = group.getFormat(j).metadata ?: continue
                for (k in 0 until metadata.length()) {
                    when (val entry = metadata.get(k)) {
                        is CommentFrame -> {
                            if (entry.id.equals("USLT", ignoreCase = true)) {
                                normalizeLyrics(entry.text)?.let { return it }
                            } else if (entry.id.equals("COMM", ignoreCase = true) &&
                                entry.description.contains("lyr", ignoreCase = true)
                            ) {
                                commFallback = normalizeLyrics(entry.text)
                            }
                        }

                        is BinaryFrame -> {
                            // Media3's Id3Decoder does not reliably decode
                            // USLT into a CommentFrame for MP3 — it is
                            // instead surfaced as an opaque BinaryFrame
                            // (see https://github.com/androidx/media/issues/922,
                            // still open). Decode the raw ID3v2 USLT
                            // payload ourselves per the spec.
                            if (entry.id.equals("USLT", ignoreCase = true)) {
                                decodeUslt(entry.data)?.let { normalizeLyrics(it)?.let { value -> return value } }
                            }
                        }

                        is TextInformationFrame -> {
                            // MP4/M4A's "©lyr" iTunes-style atom is
                            // surfaced as a text-information frame keyed
                            // by its raw atom name.
                            if (entry.id.contains("lyr", ignoreCase = true)) {
                                val joined = entry.values.joinToString("\n").trim()
                                normalizeLyrics(joined)?.let { return it }
                            }
                        }

                        is VorbisComment -> {
                            // FLAC/OGG convention used by most taggers
                            // (Mp3tag, foobar2000, etc.).
                            if (entry.key.equals("LYRICS", ignoreCase = true) ||
                                entry.key.equals("UNSYNCEDLYRICS", ignoreCase = true)
                            ) {
                                normalizeLyrics(entry.value)?.let { return it }
                            }
                        }

                        else -> Unit
                    }
                }
            }
        }

        return normalizeLyrics(commFallback)
    }

    /**
     * Manually decodes a raw ID3v2 USLT ("Unsynchronised lyrics/text
     * transcription") frame payload per the ID3v2.3/2.4 spec:
     *
     * ```
     * [1 byte text encoding][3 bytes language][content descriptor,
     * terminated][actual lyrics text, to end of frame]
     * ```
     *
     * Only needed as a fallback for the [BinaryFrame] case above — see
     * that call site for why Media3 can hand us the frame in this form.
     */
    private fun decodeUslt(data: ByteArray): String? {
        // Reject oversized raw payloads before creating any decoded String.
        if (data.size > MAX_LYRICS_BYTES) {
            throw ResourceException("Embedded lyrics exceed byte limit")
        }
        // encoding(1) + language(3) + at minimum a 1-byte terminator.
        if (data.size < 5) return null

        val (charset, terminatorWidth) = when (data[0].toInt() and 0xFF) {
            0 -> Charsets.ISO_8859_1 to 1
            1 -> Charsets.UTF_16 to 2 // includes a BOM
            2 -> Charsets.UTF_16BE to 2
            3 -> Charsets.UTF_8 to 1
            else -> return null // unknown encoding byte — refuse to guess
        }

        // Skip the 3-byte language code, then the (possibly empty)
        // terminated content descriptor that precedes the actual lyrics.
        var descriptorEnd = 4
        if (terminatorWidth == 1) {
            while (descriptorEnd < data.size && data[descriptorEnd].toInt() != 0) {
                descriptorEnd++
            }
            descriptorEnd += 1
        } else {
            while (descriptorEnd + 1 < data.size &&
                !(data[descriptorEnd].toInt() == 0 && data[descriptorEnd + 1].toInt() == 0)
            ) {
                descriptorEnd += 2
            }
            descriptorEnd += 2
        }
        if (descriptorEnd >= data.size) return null

        val textBytes = data.copyOfRange(descriptorEnd, data.size)
        return String(textBytes, charset).trim().ifEmpty { null }
    }
    private fun normalizeLyrics(value: String?): String? {
        val text = value?.removePrefix("\uFEFF")?.trim() ?: return null
        if (text.isEmpty()) return null
        if (text.length > MAX_LYRICS_CHARS) {
            throw ResourceException("Embedded lyrics exceed character limit")
        }
        return text
    }

}
