package com.example.musicplayer.playback

import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin

/**
 * Lightweight 8D-style stereo panner. It creates a slow left/right movement
 * on decoded stereo PCM; it is not a true 3D/HRTF surround renderer.
 */
@OptIn(UnstableApi::class)
class EightDAudioProcessor : BaseAudioProcessor() {
    @Volatile private var enabled = false
    @Volatile private var targetIntensity = 0.45f
    @Volatile private var speedHz = 0.16f

    private var sampleRate = 44_100
    private var encoding = C.ENCODING_INVALID
    private var phase = 0.0
    private var smoothedIntensity = 0.0

    fun update(enabled: Boolean, intensity: Float, speedHz: Float) {
        this.enabled = enabled
        targetIntensity = intensity.coerceIn(0f, 1f)
        this.speedHz = speedHz.coerceIn(0.04f, 0.7f)
    }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.channelCount != 2 ||
            (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT &&
                inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT)) {
            return AudioProcessor.AudioFormat.NOT_SET
        }
        sampleRate = inputAudioFormat.sampleRate.coerceAtLeast(1)
        encoding = inputAudioFormat.encoding
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val frameSize = if (encoding == C.ENCODING_PCM_FLOAT) 8 else 4
        val remaining = inputBuffer.remaining()
        val frameCount = remaining / frameSize
        if (frameCount <= 0) {
            inputBuffer.position(inputBuffer.limit())
            return
        }
        val output = replaceOutputBuffer(frameCount * frameSize).order(ByteOrder.nativeOrder())
        val input = inputBuffer.order(ByteOrder.nativeOrder())
        if ((!enabled || targetIntensity <= 0.0001f) && smoothedIntensity < 0.0001) {
            val alignedInput = input.duplicate()
            alignedInput.limit(alignedInput.position() + frameCount * frameSize)
            output.put(alignedInput)
            inputBuffer.position(inputBuffer.limit())
            output.flip()
            return
        }
        val phaseStep = (2.0 * PI * speedHz.toDouble()) / sampleRate.toDouble()

        repeat(frameCount) {
            val requested = if (enabled) targetIntensity.toDouble() else 0.0
            // ~45 ms smoothing avoids abrupt image jumps/clicks after toggling.
            smoothedIntensity += (requested - smoothedIntensity) * 0.0005
            val pan = sin(phase) * smoothedIntensity
            // Balance the channels around unity gain: the centre position
            // never attenuates both channels, avoiding an unwanted -3 dB dip.
            val leftGain = if (pan > 0.0) 1.0 - pan else 1.0
            val rightGain = if (pan < 0.0) 1.0 + pan else 1.0

            if (encoding == C.ENCODING_PCM_FLOAT) {
                val left = input.getFloat()
                val right = input.getFloat()
                output.putFloat((left * leftGain).toFloat().coerceIn(-1f, 1f))
                output.putFloat((right * rightGain).toFloat().coerceIn(-1f, 1f))
            } else {
                val left = input.getShort().toInt()
                val right = input.getShort().toInt()
                output.putShort((left * leftGain).toInt().coerceIn(-32768, 32767).toShort())
                output.putShort((right * rightGain).toInt().coerceIn(-32768, 32767).toShort())
            }

            phase += phaseStep
            if (phase >= 2.0 * PI) phase -= 2.0 * PI
        }

        // getShort/getFloat already advanced the input cursor; discard any
        // incomplete trailing bytes in this aligned PCM buffer defensively.
        inputBuffer.position(inputBuffer.limit())
        output.flip()
    }
}
