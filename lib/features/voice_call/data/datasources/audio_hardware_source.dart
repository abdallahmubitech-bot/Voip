import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/errors/exceptions.dart';
import '../../../../core/utils/app_logger.dart';
import '../../../../core/utils/constants.dart';
import 'audio_processor.dart';
import 'capture_silence_detector.dart';

/// One way of opening the microphone.
///
/// Android is wildly inconsistent here: the *best* configuration (voice
/// communication + hardware echo cancellation) is silent on some devices, while
/// the *safest* one (plain microphone) always works but echoes on a
/// loudspeaker. So the app tries them in order and keeps the first that produces
/// real samples — see [AudioHardwareSource._escalateCaptureProfile].
class AudioCaptureProfile {
  const AudioCaptureProfile({
    required this.name,
    required this.audioSource,
    required this.echoCancellation,
    required this.noiseSuppression,
    required this.voiceProcessing,
    required this.description,
  });

  final String name;
  final AudioSource audioSource;
  final bool echoCancellation;
  final bool noiseSuppression;
  final bool voiceProcessing;

  /// Shown in the call screen's diagnostics line and in the logs.
  final String description;

  static const AudioCaptureProfile voiceCommunication = AudioCaptureProfile(
    name: 'voice_communication + AEC',
    audioSource: AudioSource.voice_communication,
    echoCancellation: true,
    noiseSuppression: true,
    voiceProcessing: true,
    description: 'phone-call path with hardware echo/noise processing',
  );

  static const AudioCaptureProfile voiceCommunicationNoAec = AudioCaptureProfile(
    name: 'voice_communication',
    audioSource: AudioSource.voice_communication,
    echoCancellation: false,
    noiseSuppression: true,
    voiceProcessing: true,
    description: 'phone-call path without hardware echo cancellation',
  );

  static const AudioCaptureProfile microphone = AudioCaptureProfile(
    name: 'microphone + software DSP',
    audioSource: AudioSource.microphone,
    echoCancellation: false,
    noiseSuppression: false,
    voiceProcessing: false,
    description: 'raw microphone cleaned up entirely in software',
  );

  /// Ordered best → safest. The last entry is the one that works everywhere.
  static const List<AudioCaptureProfile> fallbackChain = <AudioCaptureProfile>[
    voiceCommunication,
    voiceCommunicationNoAec,
    microphone,
  ];
}

/// Result of the on-device audio self-test ("can this phone hear and speak?").
class AudioSelfTestResult {
  const AudioSelfTestResult({
    required this.capturePeak,
    required this.framesCaptured,
    required this.playbackStarted,
    required this.profile,
  });

  /// Loudest sample seen while recording, 0…1.
  final double capturePeak;
  final int framesCaptured;
  final bool playbackStarted;
  final String profile;

  bool get microphoneWorks => capturePeak > 0.01 && framesCaptured > 5;

  String get summary {
    if (!microphoneWorks) {
      return 'The microphone produced no sound. Check the Android permission, '
          'then try again — nothing else can work until this does.';
    }
    if (!playbackStarted) {
      return 'The microphone works (peak ${(capturePeak * 100).round()}%), '
          'but the speaker could not be opened.';
    }
    return 'Microphone and speaker both work '
        '(peak ${(capturePeak * 100).round()}%, profile "$profile").';
  }
}

/// Owns the native audio device: microphone capture and speaker playback.
///
/// * Capture is delivered as a plain `Stream<Uint8List>` of raw little-endian
///   PCM 16 kHz / 16-bit / mono — exactly the format the ESP32 expects — after
///   the software voice-processing chain in [AudioProcessor].
/// * Playback is a push model (`feedPlayback`): the jitter buffer decides the
///   cadence, the native player just consumes the bytes.
/// * Capture opens through a fallback chain and self-heals if a device hands
///   back digital silence, which is what makes "no audio at all" survivable.
///
/// Both directions are driven on the platform's own threads; the Dart side only
/// moves buffers, so the main isolate is never blocked.
class AudioHardwareSource {
  AudioHardwareSource({
    FlutterSoundRecorder? recorder,
    FlutterSoundPlayer? player,
    AppLogger? logger,
    AudioProcessor? processor,
    CaptureSilenceDetector? silenceDetector,
    List<AudioCaptureProfile>? profiles,
  })  : _recorder = recorder ?? FlutterSoundRecorder(),
        _player = player ?? FlutterSoundPlayer(),
        _log = logger ?? const AppLogger('AudioHW'),
        _processor = processor ?? AudioProcessor(),
        _silenceDetector = silenceDetector ?? CaptureSilenceDetector(),
        _profiles = profiles ?? AudioCaptureProfile.fallbackChain;

  final FlutterSoundRecorder _recorder;
  final FlutterSoundPlayer _player;
  final AppLogger _log;
  final AudioProcessor _processor;
  final CaptureSilenceDetector _silenceDetector;
  final List<AudioCaptureProfile> _profiles;

  final StreamController<Uint8List> _captureController =
      StreamController<Uint8List>.broadcast();

  late final StreamSink<Uint8List> _captureSink =
      _ForwardingSink(_captureController, _onRecorderBlock);

  bool _initialised = false;
  bool _capturing = false;
  bool _playing = false;
  bool _disposed = false;
  bool _escalating = false;
  Object? _lastPlaybackError;

  int _profileIndex = 0;
  bool _captureSilent = false;
  double _playbackGain = 1.0;
  double _micLevel = 0;

  /// Serialises `feedUint8FromStream` calls: flutter_sound requires back pressure
  /// (one awaited feed at a time), so frames are chained instead of fired in
  /// parallel. The chain lives off the UI isolate's critical path.
  Future<void> _feedChain = Future<void>.value();
  int _queuedFeeds = 0;

  /// Raw PCM frames straight from the microphone (post-processing).
  Stream<Uint8List> get captureStream => _captureController.stream;

  bool get isCapturing => _capturing;

  bool get isPlaying => _playing;

  /// Last playback-side failure, surfaced to the UI on the active call screen.
  Object? get lastPlaybackError => _lastPlaybackError;

  /// Name of the capture configuration currently in use.
  String get activeProfileName => _profiles[_profileIndex].name;

  /// True when every fallback produced silence — the phone's mic is not
  /// delivering data, and the far side genuinely cannot hear this handset.
  bool get captureSilent => _captureSilent;

  /// Peak microphone level of the last block, 0…1 (for the call screen meter).
  double get micLevel => _micLevel;

  /// Peak level of the audio most recently sent to the speaker, 0…1.
  double get playbackLevel => _processor.playbackPeak;

  /// Output gain for the speaker path; the repository raises this while the
  /// loudspeaker is on so the call is audible across a room.
  double get playbackGain => _playbackGain;

  set playbackGain(double value) {
    _playbackGain = value.clamp(0.5, 4.0);
  }

  /// Enables the software echo guard (used while the loudspeaker is on).
  void setEchoGuard({required bool enabled}) {
    _processor.echoGuardEnabled = enabled;
    _log.d('echo guard ${enabled ? 'on' : 'off'}');
  }

  /// How much the microphone is being ducked by the echo guard, 1.0 = untouched.
  double get echoGuardDucking => _processor.echoGuardDucking;

  Future<void> initialize() async {
    if (_initialised || _disposed) {
      return;
    }
    try {
      await _recorder.openRecorder();
      await _recorder.setSubscriptionDuration(
        const Duration(milliseconds: AudioConstants.frameDurationMs),
      );
      await _player.openPlayer();
      _initialised = true;
      _log.d('audio engine ready (16 kHz / 16-bit / mono, voice processing on)');
    } catch (error, stackTrace) {
      throw AudioEngineException(
        'The microphone/speaker engine could not be opened.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Requests `RECORD_AUDIO` and throws [MicrophonePermissionException] when the
  /// operator declined (distinct from a permanently-denied state, which needs a
  /// trip to the system settings).
  Future<void> ensureMicrophonePermission() async {
    final status = await Permission.microphone.request();
    if (status.isGranted || status.isLimited) {
      return;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      throw const MicrophonePermissionException(
        'Microphone access is blocked. Enable it for this app in Settings, '
        'then start the call again.',
      );
    }
    throw const MicrophonePermissionException(
      'Microphone permission was denied, so the other side would not hear you.',
    );
  }

  /// Starts microphone capture and returns the raw PCM stream.
  Future<Stream<Uint8List>> startCapture() async {
    if (_disposed) {
      throw const AudioEngineException('Audio engine has been disposed.');
    }
    if (_capturing) {
      return captureStream;
    }
    await ensureMicrophonePermission();
    await initialize();

    // Try each profile until one actually opens; a device may refuse
    // VOICE_COMMUNICATION outright, or refuse the AEC flag inside it.
    Object? lastError;
    for (var attempt = 0; attempt < _profiles.length; attempt++) {
      try {
        await _startRecorderWithProfile(_profileIndex);
        _captureSilent = false;
        _silenceDetector.reset();
        _processor.reset();
        _capturing = true;
        _log.i('capture started — ${_profiles[_profileIndex].name} '
            '(${_profiles[_profileIndex].description})');
        return captureStream;
      } catch (error) {
        lastError = error;
        _log.w('capture profile "${_profiles[_profileIndex].name}" refused: '
            '$error');
        if (_profileIndex >= _profiles.length - 1) {
          break;
        }
        _profileIndex++;
      }
    }

    throw AudioEngineException(
      'Microphone capture could not start on this device.',
      cause: lastError,
      stackTrace: lastError == null ? null : StackTrace.current,
    );
  }

  Future<void> _startRecorderWithProfile(int index) async {
    final profile = _profiles[index];
    await _recorder.startRecorder(
      codec: Codec.pcm16,
      toStream: _captureSink,
      numChannels: AudioConstants.channelCount,
      sampleRate: AudioConstants.sampleRate,
      bitRate: AudioConstants.sampleRate * AudioConstants.bitsPerSample,
      bufferSize: AudioConstants.captureBufferBytes,
      audioSource: profile.audioSource,
      enableVoiceProcessing: profile.voiceProcessing,
      enableNoiseSuppression: profile.noiseSuppression,
      enableEchoCancellation: profile.echoCancellation,
    );
  }

  /// Digital silence for a whole second means this capture configuration does
  /// not work on this phone. Reopen with the next fallback, keeping the same
  /// stream alive so the repository never notices.
  Future<void> _escalateCaptureProfile() async {
    if (_escalating || !_capturing || _disposed) {
      return;
    }
    if (_profileIndex >= _profiles.length - 1) {
      _captureSilent = true;
      _log.e('capture is silent in every available profile — the far side '
          'will not hear this handset');
      return;
    }
    _escalating = true;
    final failed = _profiles[_profileIndex].name;
    _profileIndex++;
    try {
      _log.w('microphone returned silence with "$failed" — switching to '
          '"${_profiles[_profileIndex].name}"');
      await _recorder.stopRecorder();
      _silenceDetector.reset();
      _processor.reset();
      await _startRecorderWithProfile(_profileIndex);
      _captureSilent = false;
      _log.i('capture recovered with "${_profiles[_profileIndex].name}"');
    } catch (error, stackTrace) {
      _log.e('capture profile escalation failed', error, stackTrace);
      _captureSilent = true;
    } finally {
      _escalating = false;
    }
  }

  /// Called for every block the native recorder produces.
  void _onRecorderBlock(Uint8List block) {
    if (_disposed || block.isEmpty) {
      return;
    }
    // Watchdog first: it must see the raw device output, before any gain.
    if (_silenceDetector.add(block)) {
      unawaited(_escalateCaptureProfile());
    }

    final processed = _processor.processCapture(block);
    _micLevel = _processor.capturePeak;
    if (!_captureController.isClosed) {
      _captureController.add(processed);
    }
  }

  Future<void> stopCapture() async {
    if (!_capturing) {
      return;
    }
    _capturing = false;
    _silenceDetector.reset();
    try {
      await _recorder.stopRecorder();
      _log.i('capture stopped');
    } catch (error, stackTrace) {
      _log.e('stopRecorder failed', error, stackTrace);
    }
  }

  /// Opens the low-latency PCM playback path.
  Future<void> startPlayback() async {
    if (_disposed) {
      throw const AudioEngineException('Audio engine has been disposed.');
    }
    if (_playing) {
      return;
    }
    await initialize();
    try {
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: AudioConstants.channelCount,
        sampleRate: AudioConstants.sampleRate,
        interleaved: true,
        // 2048-byte native buffer ≈ 64 ms: still phone-call latency, but it
        // rides out Wi-Fi jitter instead of turning every hiccup into a click.
        bufferSize: AudioConstants.playbackBufferBytes,
      );
      _playing = true;
      _lastPlaybackError = null;
      _log.i('playback started');
    } catch (error, stackTrace) {
      throw AudioEngineException(
        'Speaker playback could not start.',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Fire-and-forget: the jitter buffer calls this every 40 ms. Failures are
  /// recorded instead of thrown so one bad buffer cannot tear down the call.
  void feedPlayback(Uint8List pcm) {
    if (!_playing || pcm.isEmpty) {
      return;
    }
    // If the native sink is more than ~200 ms behind, drop instead of growing
    // latency: a glitch is better than a permanently delayed conversation.
    if (_queuedFeeds > 5) {
      _log.w('playback backlog — dropping 40 ms frame');
      return;
    }
    final processed = _processor.processPlayback(pcm, gain: _playbackGain);
    // Feed the echo guard: this is how loud the speaker is right now.
    _processor.noteFarEndLevel(_processor.playbackPeak);
    _queuedFeeds++;
    _feedChain = _feedChain
        .then<void>((_) => _player.feedUint8FromStream(processed))
        .catchError((Object error, StackTrace stack) {
      _lastPlaybackError = error;
      _log.e('feedUint8FromStream failed', error, stack);
    }).whenComplete(() {
      _queuedFeeds--;
    });
  }

  Future<void> stopPlayback() async {
    if (!_playing) {
      return;
    }
    _playing = false;
    _queuedFeeds = 0;
    _feedChain = Future<void>.value();
    try {
      await _player.stopPlayer();
      _log.i('playback stopped');
    } catch (error, stackTrace) {
      _log.e('stopPlayer failed', error, stackTrace);
    }
  }

  /// Records two seconds of microphone audio and immediately plays it back
  /// through the speaker.
  ///
  /// This is the fastest way to tell a broken *phone* from a broken *call*: it
  /// exercises the microphone, the processing chain, the player and the routing
  /// without involving Wi-Fi or the far end at all.
  Future<AudioSelfTestResult> runSelfTest({
    Duration duration = const Duration(seconds: 2),
  }) async {
    await ensureMicrophonePermission();
    await initialize();

    if (_capturing) {
      await stopCapture();
    }

    final collected = <Uint8List>[];
    final done = Completer<void>();
    final buffer = StreamController<Uint8List>();
    late final StreamSubscription<Uint8List> sub;
    sub = buffer.stream.listen((Uint8List block) {
      collected.add(block);
      if (collected.length >= 40 && !done.isCompleted) {
        done.complete();
      }
    });

    final profile = _profiles[_profileIndex];
    try {
      await _recorder.startRecorder(
        codec: Codec.pcm16,
        toStream: buffer.sink,
        numChannels: AudioConstants.channelCount,
        sampleRate: AudioConstants.sampleRate,
        bitRate: AudioConstants.sampleRate * AudioConstants.bitsPerSample,
        bufferSize: AudioConstants.captureBufferBytes,
        audioSource: profile.audioSource,
        enableVoiceProcessing: profile.voiceProcessing,
        enableNoiseSuppression: profile.noiseSuppression,
        enableEchoCancellation: profile.echoCancellation,
      );
    } catch (error, stackTrace) {
      await sub.cancel();
      await buffer.close();
      throw AudioEngineException(
        'The microphone could not be opened for the self-test.',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    // Wait for ~2 s of capture, then stop.
    try {
      await done.future.timeout(duration + const Duration(seconds: 1));
    } on TimeoutException {
      // Fewer blocks than expected is itself a result: report what we have.
    }
    await _recorder.stopRecorder();
    await sub.cancel();
    await buffer.close();

    var peak = 0.0;
    var frames = 0;
    for (final block in collected) {
      final blockPeak = AudioProcessor.peakOf(block);
      if (blockPeak > peak) {
        peak = blockPeak;
      }
      frames += block.length ~/ AudioConstants.bytesPerFrame ~/ 1;
    }

    var playbackStarted = false;
    try {
      await startPlayback();
      playbackStarted = _playing;
    } catch (error, stackTrace) {
      _log.e('self-test playback failed', error, stackTrace);
    }

    final result = AudioSelfTestResult(
      capturePeak: peak,
      framesCaptured: frames,
      playbackStarted: playbackStarted,
      profile: profile.name,
    );
    _log.i('self-test: ${result.summary}');
    return result;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stopCapture();
    await stopPlayback();
    try {
      await _recorder.closeRecorder();
      await _player.closePlayer();
    } catch (error) {
      _log.e('audio teardown failed', error);
    }
    await _captureController.close();
  }
}

/// Lets `flutter_sound` write into our controller without ever closing it, and
/// gives every block a chance to be processed first.
class _ForwardingSink implements StreamSink<Uint8List> {
  _ForwardingSink(this._controller, this._onBlock);

  final StreamController<Uint8List> _controller;
  final void Function(Uint8List block) _onBlock;

  @override
  void add(Uint8List event) {
    if (!_controller.isClosed) {
      _onBlock(event);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_controller.isClosed) {
      _controller.addError(error, stackTrace);
    }
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    // Intentionally ignored: the controller is owned by AudioHardwareSource and
    // must survive recorder restarts (the profile fallback restarts it).
  }

  @override
  Future<void> get done => Future<void>.value();
}
