# Local Wi-Fi Full-Duplex VoIP (Flutter ⇄ ESP32)

A production-shaped Flutter client for **username-addressed voice calls over a local
Wi-Fi network**, signalled with JSON text frames and streamed as raw PCM binary
frames through an **ESP32 WebSocket router** (`ws://192.168.4.1:81`).

Feature-first Clean Architecture · BLoC with explicit state classes · 40 ms PCM
frames · jitter-buffered playback · busy-line handling with a native alert.

---

> **Project guide (PDF).** `docs/ESP32_VoIP_Project_Guide.pdf` explains the whole system in
> plain language for a non-technical reader, then hands over to builder notes, a code map,
> a scaling roadmap and the wire protocol. Regenerate it with
> `pip install --user reportlab pymupdf && python3 tools/build_pdf.py`.

---

## 1. What it does

| # | Feature | Behaviour |
|---|---------|-----------|
| 1 | **Registration** | On join, sends `{"type":"register","from":"User_A"}`, stores the routing byte the router assigns, and **re-registers automatically after a reconnect**. |
| 2 | **Outgoing call** | `make_call` → ringback tone + "Ringing…" screen. Peer answer switches to the live-call screen and opens the audio pipeline. |
| 3 | **Busy line** | On `line_busy`: ringback is stopped **immediately**, the pending session is dropped, and a blocking platform-adaptive alert shows the router's message (`"Please wait, the user is on another call."`). |
| 4 | **Incoming call** | Ringtone + accept/decline; 45 s unanswered → auto-decline and a "Missed call" notice. |
| 5 | **Full-duplex audio** | Mic → 1280-byte PCM frames → `[targetId][pcm]` binary WebSocket frames; inbound binary → routing check → jitter buffer → speaker. |
| 6 | **Failure handling** | Reconnecting socket with backoff, mid-call link loss → call ended with a clear reason, mic-permission denial → call ended with an actionable message, malformed frames never crash the stream. |

---

## 2. Architecture

```
lib/
├── main.dart                     # --dart-define=VOIP_SERVER_URL override, DI bootstrap
├── app.dart                      # MaterialApp + Repository/Bloc providers
├── app_shell.dart                # state → screen routing, busy-line dialog, end-of-call banner
├── core/
│   ├── audio/ringtone_service.dart      # ringback/ringtone (audioplayers), behind an interface
│   ├── di/injector.dart                 # composition root (get_it)
│   ├── errors/{exceptions,failures}.dart # sealed, mapped 1:1
│   ├── network/
│   │   ├── websocket_service.dart       # shared transport: connect, ping, backoff, frame demux
│   │   ├── websocket_config.dart        # URI, timeouts, reconnect policy
│   │   └── connection_status.dart       # WebSocketStatus
│   ├── theme/app_theme.dart
│   └── utils/{constants,result,app_logger}.dart
└── features/
    ├── auth_registration/               # Feature 1
    │   ├── data/
    │   │   ├── datasources/registration_remote_data_source.dart
    │   │   ├── models/registration_message_model.dart
    │   │   └── repositories/registration_repository_impl.dart
    │   ├── domain/
    │   │   ├── entities/device_identity.dart
    │   │   ├── repositories/registration_repository.dart
    │   │   └── usecases/register_device_usecase.dart
    │   └── presentation/
    │       ├── controllers/{registration_controller,registration_event,registration_state}.dart
    │       └── screens/registration_screen.dart
    └── voice_call/                      # Feature 2
        ├── data/
        │   ├── datasources/
        │   │   ├── call_websocket_source.dart      # signalling frames + binary PCM
        │   │   ├── audio_hardware_source.dart      # flutter_sound capture/playback
        │   │   ├── pcm_chunker.dart                # re-frame to exactly 40 ms
        │   │   └── playback_jitter_buffer.dart     # prefill + 40 ms drain ticks
        │   ├── models/{call_signal_model,audio_packet_model}.dart
        │   └── repositories/call_repository_impl.dart
        ├── domain/
        │   ├── entities/{call_signal,call_session,audio_stream_stats}.dart
        │   ├── repositories/call_repository.dart
        │   └── usecases/{connect_to_call,make_call,answer_call,reject_call,end_call,
        │                 mute_audio,stream_audio,watch_call_signals}_usecase.dart
        └── presentation/
            ├── controllers/{call_bloc,call_event,call_state}.dart
            ├── screens/{dial_pad_screen,incoming_call_screen,active_call_screen}.dart
            └── widgets/{call_avatar,round_call_button,connection_badge}.dart
```

**Dependency rule:** `presentation → domain ← data`. The presentation layer only
knows `CallRepository` / `RegistrationRepository` interfaces and use cases; the
data layer is the only place that touches WebSockets, `flutter_sound`, or JSON.

### Presentation states (exhaustive, no booleans)

```dart
CallInitial   → dial pad is interactive
CallConnecting→ socket opening, make_call in flight
CallRinging   → outgoing, ringback playing
CallIncoming  → inbound ring (carries caller id)
CallActive    → audio live (startedAt, isMuted, stats)
CallLineBusy  → ringback halted, dialog on screen
CallEnded     → terminal; CallEndReason drives the copy
```

---

## 3. Audio pipeline

```
                 ┌──────────────────────── capture path (25 fps) ───────────────────────┐
 mic ─► flutter_sound (PCM16/16 kHz/mono, toStream)   ← profile fallback chain
     ─► CaptureSilenceDetector all-zero buffers? → reopen with the next profile
     ─► AudioProcessor         high-pass → low-pass → adaptive gate → AGC → limiter
     ─► PcmChunker            arbitrary blocks → exactly 1280-byte frames
     ─► AudioPacketModel      [peerId][pcm]  (1-byte routing header)
     ─► WebSocketService      binary frame (dropped, never queued, while offline)

                 ┌──────────────────────── playback path ────────────────────────────────┐
 WS binary ─► isPlausibleFrame? ─► targetId == myId || 0 ?
           ─► strip header  ─► PlaybackJitterBuffer (prefill 4 frames, 40 ms ticks)
           ─► AudioProcessor (high-pass + speaker gain + limiter)
           ─► flutter_sound.feedUint8FromStream()  (serialised / back-pressured)
```

Design notes that matter in the field:

- **Frame math is centralised** in `AudioConstants`: `16000 × 0.040 × 2 = 1280` bytes.
- **No audio is ever queued while disconnected** — stale voice is worse than silence.
- **Backlog caps both ways**: `PcmChunker` drops whole frames past 5 frames of
  backlog; the player drops a frame if its native sink is >200 ms behind.
- **Mute drops the samples at the source**, so nothing is uploaded at all.
- **Nothing blocks the UI isolate**: capture and playback run on the platform's
  own audio threads; Dart only copies buffers. If you later add resampling or
  echo cancellation in Dart, move it into an `Isolate` — the seam is
  `AudioHardwareSource.captureStream`.
- **`feedFromStream` is awaited through a serialised chain** (`_feedChain`),
  because `flutter_sound` requires one awaited feed at a time.

The wire format is documented in [`docs/protocol.md`](docs/protocol.md), including
a firmware sketch for the ESP32 side. The **actual firmware** lives in
[`firmware/esp32_voip_router/esp32_voip_router.ino`](firmware/esp32_voip_router/esp32_voip_router.ino)
(setup notes in [`firmware/README.md`](firmware/README.md)).

---

## 4. Verified build (this repository was actually compiled)

| Item | Value |
| --- | --- |
| Flutter | 3.47.9 stable (Dart 3.13.7) |
| Android SDK | platform 36 / build-tools 36.0.0, JDK 17 |
| `flutter analyze` | **No issues found** |
| `flutter test` | **53/53 passing** (22 call-flow + 20 audio DSP/watchdog + 5 echo-guard + 6 noise/click) |
| Artifact | `esp32_voip-v1.2.0-arm64-release.apk` — 21.6 MB, ABI **arm64-v8a**, minSdk 24, targetSdk 36 |
| Version | 1.3.0+4 — speech-band filtering, adaptive noise floor, click-free playback, loudspeaker UX |
| Signing | release keystore (`CN=Local VoIP Demo`), APK Signature Scheme v2 (verified with `apksigner`) |

Build it yourself:

```bash
flutter pub get
flutter build apk --release --target-platform=android-arm64   # ~21 MB, all modern phones
# or, for everything (arm64 + armv7 + x86_64):
flutter build apk --release
```

### Low-RAM machines (2 GB, no swap)

On a very small machine the Dart AOT compiler (`gen_snapshot`, ~250 MB) and the
Gradle JVM compete for memory and the kernel OOM-kills the build. The pipeline
can be split so the two never overlap:

```bash
./tools/build-apk-two-phase.sh android-arm64
```

Phase 1 runs `flutter assemble` (Dart AOT + asset bundle, no JVM), phase 2 runs
`./gradlew assembleRelease -x compileFlutterBuildRelease` so Gradle only compiles
Kotlin/Java and packages the already-built snapshot. The script also passes
`-Pdisable-abi-filtering=true`, because the Flutter Gradle plugin otherwise
re-adds every ABI to `abiFilters` and ships plugin `.so` files with no matching
`libapp.so` for them.

Release signing is optional: `android/key.properties` + `android/release-key.jks`
are git-ignored, and `android/app/build.gradle.kts` falls back to the debug key
when they are absent, so a fresh clone still builds.

## 5. Call audio quality (echo, noise, loudspeaker)

A full-duplex VoIP call on a phone dies from three things that a normal cellular
call hides from you. All three are now handled:

| Problem | What was wrong | Fix in this version |
| --- | --- | --- |
| **Echo / howling** ("unwanted sound") | Audio played on the **loudspeaker** while the mic was open → the far end's voice re-entered the mic, and the phone was not in voice-call mode, so **no echo canceller was attached** | `AudioManager.MODE_IN_COMMUNICATION` + **earpiece by default** (`AudioRouteService`) and capture opened as `AudioSource.voice_communication` with `enableEchoCancellation: true` — the platform AEC is attached to the recorder's audio session |
| **Background hiss / room noise** | Noise suppressor never enabled | `enableNoiseSuppression: true`, plus AGC via voice processing |
| **Crackle / clicks** | 1024-byte native buffer + a 3-frame jitter prefill under-ran on Wi-Fi jitter | 2048-byte playback buffer, 4096-byte capture blocks, 4-frame (160 ms) prefill |

What the app now does when a call becomes active, in order:

```dart
await route.enterCallMode();          // AudioManager: MODE_IN_COMMUNICATION, earpiece, voice-call volume
await route.setLoudspeaker(false);    // never start on the speaker
await audio.startPlayback();          // PCM16 16 kHz out
await audio.startCapture();           // VOICE_COMMUNICATION + AEC + NS + AGC in
…
await route.exitCallMode();           // MODE_NORMAL when the call ends
```

### Loudspeaker

The active-call screen has three controls: **Mute · Speaker/Earpiece · End**.
`CallActive.isLoudspeaker` drives the icon, `SetLoudspeakerUseCase` flips it, and
the platform side is `audioManager.isSpeakerphoneOn` (the same switch a dialer
uses). Expect *some* echo on speakerphone — that is true of real phones too; the
AEC keeps it from howling.

**Verified, not assumed:** `flutter_sound` ships its Android engine as a closed
AAR, so I decompiled it (`flutter_sound_core-9.30.0.aar`) and confirmed
`FlautoRecorderEngine` really calls `AcousticEchoCanceler.create(sessionId)`,
`NoiseSuppressor.create(sessionId)` and opens `AudioRecord` with the source from
the enum (`voice_communication` = platform value 7). The flags are not no-ops.

### If you still hear artefacts, check these (firmware side)

| Symptom | Real cause | Where to look |
| --- | --- | --- |
| Your own voice back, delayed ~200 ms | The router forwards your frames **back to the sender** (e.g. `targetId == 0` broadcast that includes the sender) | `handleAudio()` in the `.ino` — it must skip `peers[i].num == num` and only bridge peers that are `callWith` each other |
| Chipmunk / slow-motion / buzzing voice | Sample-rate mismatch: the ESP32 I2S runs at 8 kHz or 48 kHz while the app sends 16 kHz | Set the ESP32 I2S to **16 000 Hz, mono, 16-bit** (`AudioConstants.sampleRate`) |
| Loud continuous whistle | Clean feedback loop (speaker + mic in the same box, e.g. a dev board with a speaker) | Use the earpiece/headset, keep the mic away from the speaker |
| Clicks every few hundred ms | Packet loss or the ESP32 not keeping up with 2 × 32 kB/s | Wi-Fi RSSI, other traffic on the SoftAP, `[stat] fwd/drop` counters |

## 6. "The call connects but nobody hears anybody" — v1.2.0

This was the field report for v1.1.0, and it has a specific, testable cause. A
VoIP call has **four** independent audio links, and a silent call means one of
them is dead:

```
 (1) mic ─► capture profile ─► (2) network ─► (3) speaker ─► (4) ear
       on-phone                    Wi-Fi          on-phone
```

Signalling can be perfect (the call “connects”) while any one of them is broken.
v1.2.0 attacks the one that fails invisibly:

### The silent-microphone bug: all-zero capture

Android hands back **digital silence** — buffers full of zeros, no exception,
stream alive — when a capture configuration is not supported by that device.
`VOICE_COMMUNICATION` with hardware AEC is the best-sounding choice and also the
one most likely to do this on certain OEMs. Every app-side counter then looks
healthy (25 frames/s sent, 256 kbit/s), the board forwards 25 frames/s of zeros,
and **both phones hear nothing**.

v1.2.0 measures instead of guessing:

| Piece | What it does |
| --- | --- |
| `AudioCaptureProfile.fallbackChain` | tries `voice_communication + AEC` → `voice_communication` (AEC off) → `microphone` + software DSP. The last one works on every Android device ever made |
| `CaptureSilenceDetector` | ignores the first ~0.5 s, then if **25 consecutive frames (1 s) peak below 8 LSB**, it declares the profile broken |
| `AudioHardwareSource._escalateCaptureProfile()` | stops and reopens the recorder on the next profile **without disturbing the stream** the call is already listening to — the call does not drop |
| Active-call screen | shows a live **You / Them** level meter and, if capture is still silent, a red note saying the far side cannot hear this phone |

### Noise, clarity and loudspeaker (software DSP)

The platform AEC/NS is the hardware half and it is not present on every device,
so v1.2.0 adds the software half — `AudioProcessor`, pure Dart, ~0.1 % of a core:

| Stage | Effect | Why it matters |
| --- | --- | --- |
| High-pass @ 110 Hz | removes DC offset, handling thump, mains hum | a loudspeaker reproduces rumble badly; cutting it makes speech clearer |
| **Speech-band low-pass @ 3.6 kHz** (v1.3.0) | two cascaded one-poles, ≈ 12 dB/octave | everything above the telephone band is hiss: preamp noise, fan whine, Wi-Fi electronics, aliasing. Cutting it is the biggest single "clearer voice" win |
| **Adaptive noise floor** (v1.3.0) | the gate threshold follows the room (fast-fall / slow-rise envelope) instead of a fixed −52 dBFS | the same settings work in a quiet bedroom and next to a fan; a noisy room no longer leaks through the gate |
| Downward expander (soft gate) | −22 dB below −52 dBFS, fully open above −34 dBFS | removes the constant hiss **between** words — the line sounds quiet instead of noisy |
| AGC (fast up, slow down) | aims for ≈ −20 dBFS RMS | a quiet talker and a loud talker arrive at the same level |
| Soft-knee limiter @ −1 dBFS | tanh bend above 0.89 | **never clips** — clipping is what makes a loud loudspeaker sound harsh |
| Speaker gain ×2.2 | applied only while the loudspeaker is on | the call is audible across a room *and* still limited |
| **Echo guard (software half-duplex)** | while the loudspeaker is on, the microphone is ducked to **−18 dB** whenever the far end is actually talking (never muted) | kills the howl/echo loop on devices whose hardware AEC is missing or weak — e.g. a dev board, or a phone with a cheap loudspeaker. Closes in ~20 ms, opens in ~120 ms, so the local talker is not chopped |

### Click-free playback (v1.3.0)

"Unwanted sound" during a call is usually not the codec — it is three playback
defects that each produce a short, sharp noise:

| Defect | What it sounded like | Fix |
| --- | --- | --- |
| Capture and playback shared one high-pass filter's memory | clicks and a thin, phasy voice whenever the two paths interleaved | each path now owns its filter state |
| Jitter-buffer starvation restarted the stream mid-waveform | a "pop" every time Wi-Fi hiccupped | the buffer reports the interruption and playback fades in over ~6 ms |
| A truncated or corrupt frame landed as an instant full-scale step | a loud crack, worst on the loudspeaker | a de-clicker caps the sample-to-sample step at 0.37 FS |

All three are unit-tested (`test/features/voice_call/audio_processor_test.dart`,
group *click suppression*) without needing a phone.

### Loudspeaker: who hears the call (v1.3.0)

The speaker control now states the trade-off instead of hiding behind an icon:

| Where | Control | Meaning |
| --- | --- | --- |
| Incoming-call screen | **Accept** / **Speaker** | accept on the earpiece (only you) or straight onto the loudspeaker (everyone nearby) |
| Active-call screen | **Loudspeaker** tile with a switch | "Everyone nearby can hear the call" ↔ "Only you can hear the call" |
| Active-call screen | round speaker button | same toggle, for muscle memory |

Turning the loudspeaker on also raises the playback gain (×2.2) and engages the
echo guard; turning it off restores earpiece routing and full microphone gain.

### Routing and volume

`MODE_IN_COMMUNICATION` plus `isSpeakerphoneOn` is not enough on modern Android.
`MainActivity` now also uses `setCommunicationDevice()` (API 31+) to select
`TYPE_BUILTIN_EARPIECE` or `TYPE_BUILTIN_SPEAKER` explicitly, re-asserts the route
**after** Flutter Sound has opened its recorder (opening it can reset the audio
mode), and forces the **voice-call stream** to 80 % (earpiece) or 100 %
(loudspeaker). A phone sitting at volume 0 on that stream is the second classic
reason a working call is silent.

### The two-minute field procedure

1. **Audio check** (ear/hearing icon on the dial pad, on *each* phone): records two
   seconds and plays it back through the loudspeaker. If you cannot hear yourself,
   the problem is that handset — permissions, a hardware fault, or volume — and it
   has nothing to do with the network, the board, or the other phone.
2. **Place a call** and watch the two meters. `You` moving and `Them` flat means
   the other phone's microphone (run step 1 there). Both flat with counters
   climbing means routing — read the log lines `first audio frame sent/received`
   and `dropped 25 audio frames addressed to device N`.
3. If both meters move but you hear nothing, it is the output path: press
   **Speaker**, then check the media/voice-call volume with the volume rocker.

Everything above is covered by tests (`flutter test`, **47 passing**), including
the gate, AGC, limiter, the echo guard's attack/release, the silence watchdog and
the profile fallback trigger.

### The two failure modes, side by side

| What you hear | Which link is broken | What the app now does |
| --- | --- | --- |
| **Nothing at all, both ways** | (1) capture — all-zero buffers from an unsupported capture profile | `CaptureSilenceDetector` escalates to the next profile mid-call; the call screen warns "this phone's microphone is returning silence" |
| **Nothing at all, one way** | (1) capture on the silent handset, or (3) output on the muted one | live **You / Them** meters; "the other phone is sending silence — run the Audio check on that handset" |
| **Howl, whistle, echo of your own voice** | (3)+(4) acoustic feedback from the loudspeaker into the microphone | earpiece by default, software echo guard on the loudspeaker, hardware AEC where available, and the router no longer reflects frames to the sender |
| **Hiss, hum, rumble, "noisy line"** | capture — room noise and DC offset | 110 Hz high-pass + downward expander (−22 dB under the speech threshold) |
| **Voice too quiet / too loud / crackly** | capture level + playback headroom | AGC to ≈ −20 dBFS, limiter at −1 dBFS, and voice-call stream volume forced to 80 %/100 % |

---

## 7. Running it

```bash
# 1. Generate the platform folders around the existing lib/ (keeps our code)
flutter create . --org com.example --platforms=android,ios --project-name esp32_voip

# 2. Dependencies
flutter pub get

# 3. Run against the router's SoftAP
flutter run --dart-define=VOIP_SERVER_URL=ws://192.168.4.1:81
```

`VOIP_SERVER_URL` defaults to `ws://192.168.4.1:81`. For `adb` port forwarding
during development: `ws://127.0.0.1:8080`.

### Android

`android/app/src/main/AndroidManifest.xml` — inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
```

and on `<application>` — **required** for `ws://` (cleartext) on Android 9+:

```xml
<application
    android:usesCleartextTraffic="true"
    ... >
```

`android/app/build.gradle` → `minSdkVersion 23` (unblocking writes for
`flutter_sound` PCM streams), and consider
`android:foregroundServiceType="microphone"` if you add a call notification.

### iOS

`ios/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is required for local Wi-Fi voice calls.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>This app talks to the ESP32 call router on your local network.</string>
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>
  <key>NSAllowsArbitraryLoads</key><true/>   <!-- ws:// to 192.168.4.1 -->
</dict>
```

Add a background mode (`audio`) only if you want calls to survive backgrounding;
otherwise end the call when the app is backgrounded.

### Tests

```bash
flutter test
```

| Test | Covers |
| --- | --- |
| `pcm_chunker_test.dart` | 1280-byte framing, carry-over, backlog cap, reset |
| `audio_packet_model_test.dart` | routing header encode/decode, torn frames, id masking |
| `call_signal_model_test.dart` | `line_busy`, `call_answered` with peer id, unknown types |
| `call_bloc_test.dart` | busy line halts ringback + state, accept opens audio with the right ids, mic denial ends the call, transport loss ends the call, mute |
| `registration_screen_test.dart` | widget-level: form renders, short username rejected before any network call, successful join exposes the routing id |
| `call_bloc_test.dart` (speaker) | calls start on the earpiece and the loudspeaker toggle flips both state and repository |

The BLoC tests use a hand-written `FakeCallRepository` (no mocking package) and a
recording ringtone double, so `flutter test` needs no extra dev dependencies.

---

## 8. Error handling matrix

| Failure | Detection | User-visible result |
| --- | --- | --- |
| Router unreachable at startup | `channel.ready` timeout (6 s) | `RegistrationFailure` + retry button |
| Socket drops while idle | `onDone` → backoff (0.5 s → 8 s) | Connection badge: *Reconnecting*; auto re-`register` |
| Socket drops mid-call | transport stream → `_onTransportStatus` | `CallEnded(networkFailure)`: "The Wi-Fi link to the router dropped…" |
| Callee busy | `line_busy` | `CallLineBusy` + native alert, ringback stopped |
| Callee unknown/offline | `peer_unavailable` | `CallEnded`: "That username is not online." |
| No answer (45 s) | ring timer | `CallEnded(timeout)`: "No answer." |
| Mic denied | `Permission.microphone.request()` | `CallEnded(permissionDenied)` + Settings hint, call discarded, `end_call` sent |
| No routing id from router | `deviceId == null` | Dial blocked with an explicit explanation |
| Malformed JSON / unknown type | `CallSignalModel` | Frame dropped + logged; stream survives |
| Router error frame | `error` | `CallEnded(server)` with the router's message |

---

## 9. Production hardening (next steps)

1. **Echo cancellation / AEC.** Full duplex on a phone speaker will feed back.
   Configure `audio_session` (`AudioSessionConfiguration.speech()`), route to the
   earpiece by default, and enable the platform AEC
   (`AVAudioSessionModeVoiceChat` / Android `VOICE_COMMUNICATION`).
2. **Opus.** 256 kbps raw PCM is comfortable on 802.11n but wasteful on a busy
   SoftAP; move to Opus (`flutter_sound` supports it) once the firmware can pay
   the codec cost.
3. **`wss://` + auth token** if the router ever leaves a trusted LAN; the
   transport is already injected as a URI.
4. **Foreground service / CallKit** for ringing when the app is backgrounded.
5. **Persist the username** (`shared_preferences`) so re-joining is one tap.
6. **Adaptive jitter buffer** (grow/shrink `prefill` from measured underruns) —
   the seam is `PlaybackJitterBuffer`.
7. **Isolate offload** if you add DSP in Dart (see §3).

---

## 10. Notes / assumptions

- One WebSocket per handset, shared by both features — matching a typical
  ESP32 `WebSocketsServer` design.
- The router assigns the routing byte; the app refuses to call without one
  rather than guessing.
- `flutter_sound` is driven in *stream* mode (`toStream` + `startPlayerFromStream`
  + `feedFromStream`). If you prefer the `record` + `audioplayers` stack, only
  `AudioHardwareSource` changes — no other layer knows which package is used.
- Ring tone WAVs live in `assets/audio/` (16 kHz mono, generated for this project).
