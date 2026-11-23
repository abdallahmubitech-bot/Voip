package com.example.esp32_voip

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the "esp32_voip/audio_route" channel.
 *
 * This is what makes the app behave like a real phone call:
 *
 *  - MODE_IN_COMMUNICATION tells the platform an uplink/downlink voice session is
 *    running. Together with the VOICE_COMMUNICATION capture source on the Dart
 *    side, that is what engages the hardware echo canceller / noise suppressor
 *    on essentially every Android device.
 *  - The output device is chosen explicitly (earpiece, or the loudspeaker when
 *    asked). API 31+ goes through setCommunicationDevice(), which is the only
 *    reliable way to move call audio on modern Android; older releases fall back
 *    to the deprecated isSpeakerphoneOn flag.
 *  - Call volume is set for the voice-call stream, which is the stream the
 *    earpiece/loudspeaker actually uses during a call. A phone at "0" on that
 *    stream is the classic reason a working call sounds completely silent.
 *  - MODE_NORMAL is restored when the call ends so music/video playback is
 *    unaffected afterwards.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "esp32_voip/audio_route"

        /** Earpiece at 80 % — comfortable, and below the feedback threshold. */
        const val EARPIECE_VOLUME_FRACTION = 0.8f

        /** Loudspeaker at full scale; the Dart side limits the samples. */
        const val SPEAKER_VOLUME_FRACTION = 1.0f
    }

    private lateinit var audioManager: AudioManager
    private var loudspeaker = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioManager =
            applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterCallMode" -> {
                        enterCallMode()
                        result.success(null)
                    }
                    "refreshCallMode" -> {
                        // Re-assert the mode and route *after* Flutter Sound has
                        // opened its recorder, which can reset the audio mode.
                        val wanted = call.argument<Boolean>("loudspeaker") ?: loudspeaker
                        enterCallMode()
                        setLoudspeaker(wanted)
                        result.success(null)
                    }
                    "exitCallMode" -> {
                        exitCallMode()
                        result.success(null)
                    }
                    "setLoudspeaker" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setLoudspeaker(enabled)
                        result.success(enabled)
                    }
                    "isLoudspeaker" -> result.success(isLoudspeaker())
                    else -> result.notImplemented()
                }
            }
    }

    private fun enterCallMode() {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        applyVolume()
    }

    private fun exitCallMode() {
        loudspeaker = false
        audioManager.mode = AudioManager.MODE_NORMAL
    }

    private fun setLoudspeaker(enabled: Boolean) {
        loudspeaker = enabled
        if (audioManager.mode != AudioManager.MODE_IN_COMMUNICATION) {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            selectCommunicationDevice(enabled)
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = enabled
        }
        applyVolume()
    }

    /** API 31+: route call audio to a named built-in device. */
    private fun selectCommunicationDevice(speaker: Boolean) {
        val wanted = if (speaker) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        } else {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
        }
        val device = audioManager.availableCommunicationDevices
            .firstOrNull { it.type == wanted }
            ?: audioManager.availableCommunicationDevices.firstOrNull()
            ?: return
        audioManager.setCommunicationDevice(device)
        // Keep the legacy flag in sync: some OEM audio HALs still read it.
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = speaker
    }

    /**
     * A call at 0 % of the voice-call stream is silent even though every counter
     * in the app looks healthy, so make sure it is never the cause.
     */
    private fun applyVolume() {
        val fraction = if (loudspeaker) SPEAKER_VOLUME_FRACTION else EARPIECE_VOLUME_FRACTION
        for (stream in intArrayOf(
            AudioManager.STREAM_VOICE_CALL,
            AudioManager.STREAM_MUSIC,
        )) {
            try {
                val max = audioManager.getStreamMaxVolume(stream)
                if (max <= 0) continue
                val target = (max * fraction).toInt().coerceIn(1, max)
                if (audioManager.getStreamVolume(stream) < target) {
                    audioManager.setStreamVolume(stream, target, 0)
                }
            } catch (ignored: SecurityException) {
                // Do Not Disturb or a device policy can forbid this; the OS
                // default volume is still usable.
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun isLoudspeaker(): Boolean = loudspeaker
}
