import 'dart:async';

// import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as ph; // path helper
import 'package:record/record.dart';
import 'package:waveform_flutter/waveform_flutter.dart' as waveform;
import 'dart:typed_data';

import 'platform_helper/platform_helper.dart';

/// A controller for managing audio recording and waveform generation.
class WaveformRecorderController extends ChangeNotifier {
  /// Creates a new instance of [WaveformRecorderController].
  ///
  ///
  /// [interval] determines how often amplitude data is emitted (default is
  /// 250ms). [encoder] specifies the audio encoding format (default is
  /// platform-dependent). [config] sets other settings like bit rate, sample
  /// rate, etc.
  WaveformRecorderController({
    this.interval = const Duration(milliseconds: 250),
    @Deprecated('Use config instead') AudioEncoder? encoder,
    RecordConfig? config,
    AudioRecorder? audioRecorder, // <-- Add this parameter
  }) : config = RecordConfig(
          encoder: encoder ??
              config?.encoder ??
              (kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc),
          numChannels: config?.numChannels ?? 1,
          bitRate: config?.bitRate ?? 128000,
          sampleRate: config?.sampleRate ?? 44100,
          device: config?.device,
          autoGain: config?.autoGain ?? false,
          echoCancel: config?.echoCancel ?? false,
          noiseSuppress: config?.noiseSuppress ?? false,
          androidConfig: config?.androidConfig ?? const AndroidRecordConfig(),
          iosConfig: config?.iosConfig ?? const IosRecordConfig(),
        ),
        _audioRecorder = audioRecorder ?? AudioRecorder();

  /// The interval at which amplitude data is emitted during recording.
  ///
  /// This determines how frequently the waveform is updated. Default is 250ms.
  final Duration interval;

  /// The audio config used for recording.
  ///
  /// Encode default is platform-dependent: WAV for web, AAC-LC for other
  /// platforms.
  final RecordConfig config;

  Stream<waveform.Amplitude>? _amplitudeStream;
  AudioRecorder? _audioRecorder;
  AudioRecorder? get audioRecorder => _audioRecorder;
  XFile? _file;
  var _length = Duration.zero;
  DateTime? _startTime;

  ///This keeps track of the time elapsed since recording was started.
  final Stopwatch _stopwatch = Stopwatch();

  /// Returns the elapsed time since the recording started,
  /// excluding any paused time.
  Duration get timeElapsed => _stopwatch.elapsed;

  ///Indicates whether audio recording is currently paused or not.
  bool get isPaused => !_stopwatch.isRunning;

  /// Indicates whether audio recording is currently in progress.
  // bool get isRecording => _audioRecorder != null;
    var isRecording = false;
  
  // bool get isRecording => _audioRecorder?.isRecording() ?? false;

  /// Provides a stream of amplitude data for generating the waveform.
  ///
  /// Throws an exception if called when not recording.
  Stream<waveform.Amplitude> get amplitudeStream =>
      _amplitudeStream ?? (throw Exception('Not recording'));

  /// The recorded audio file.
  ///
  /// This property returns the [XFile] containing the recorded audio data. It
  /// will be null if no recording has been made or if the recording process
  /// hasn't completed.
  XFile? get file => _file;

  /// The duration of the recorded audio.
  Duration get length => _length;

  /// The start time of the current or last recording session.
  DateTime? get startTime => _startTime;

  @override
  void dispose() {
    _amplitudeStream = null;
    unawaited(_audioRecorder?.dispose());
    _audioRecorder = null;
    isRecording = false;
    _file = null;
    _length = Duration.zero;
    _startTime = null;
    _stopwatch
      ..stop()
      ..reset();
    super.dispose();
  }

  /// Starts a new audio recording session.
  ///
  /// Throws an exception if already recording.
  Future<void> startRecording() async {
    debugPrint('[WaveformRecorderController] startRecording called');
    assert(_amplitudeStream == null);
    assert(_startTime == null);
    _file = null;
    _length = Duration.zero;

    try {
      debugPrint('[WaveformRecorderController] Preparing to start recording');
      // request permissions (needed for Android)
      // _audioRecorder = AudioRecorder();
      // await _audioRecorder!.hasPermission();
      isRecording = true;
      debugPrint('[WaveformRecorderController] isRecording set to true');

      // start the recording into a temp file (or in memory on the web)
      _startTime = DateTime.now();
      _length = Duration.zero;
      final ext = _extFor(config.encoder);
      debugPrint('[WaveformRecorderController] Getting temp path with extension: $ext');
      final path = await PlatformHelper.getTempPath(ext);
      debugPrint('[WaveformRecorderController] Temp path obtained: $path');
      debugPrint('[WaveformRecorderController] Starting audio recorder with config: $config');
      await _audioRecorder!.start(config, path: path);
      debugPrint('[WaveformRecorderController] Audio recorder started');
      _stopwatch.start();

      // map the amplitude types as they stream in
      debugPrint('[WaveformRecorderController] Setting up amplitude stream');
      _amplitudeStream = _audioRecorder!
          .onAmplitudeChanged(interval)
          .map(
            (a) => waveform.Amplitude(current: a.current, max: a.max),
          )
          .asBroadcastStream(); // allows multiple listeners
      debugPrint('[WaveformRecorderController] Recording started successfully');
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[WaveformRecorderController] Error in startRecording: $e\n$stack');
      rethrow;
    }
  }

  /// Stops the current audio recording session.
  ///
  /// Throws an exception if not currently recording.
  Future<void> stopRecording() async {
    debugPrint('[WaveformRecorderController] stopRecording called');
    if (_audioRecorder == null) {
      debugPrint('[WaveformRecorderController] Error: Not recording');
      throw Exception('Not recording');
    }
    assert(_file == null);
    assert(_length == Duration.zero);

    debugPrint('[WaveformRecorderController] Stopping audio recorder');
    final path = await _audioRecorder!.stop() ?? '';
    debugPrint('[WaveformRecorderController] Audio recorder stopped, path: $path');
    if (path.isNotEmpty) {
      _file = _fileFor(config.encoder, path);
      _length = _stopwatch.elapsed;
      debugPrint('[WaveformRecorderController] File created: ${_file?.path}, length: $_length');
    } else {
      debugPrint('[WaveformRecorderController] No file path returned');
    }

    // unawaited(_audioRecorder!.dispose());
    // _audioRecorder = null;
    isRecording = false;
    debugPrint('[WaveformRecorderController] isRecording set to false');

    _amplitudeStream = null;
    _startTime = null;
    _stopwatch
      ..stop()
      ..reset();
    debugPrint('[WaveformRecorderController] State cleared, notifying listeners');
    notifyListeners();
  }

  /// Pauses the current audio recording session if it is recording.
  ///
  /// Throws an exception if the recording has not been started yet.
  Future<void> pauseRecording() async {
    if (_audioRecorder == null) throw Exception('Recording not started');
    assert(_file == null);
    assert(_length == Duration.zero);

    if (await _audioRecorder!.isRecording()) {
      await _audioRecorder!.pause();
      _stopwatch.stop();
    }

    notifyListeners();
  }

  /// Resumes the current audio recording session if it was paused.
  ///
  /// Throws an exception if the recording has not been started yet.
  Future<void> resumeRecording() async {
    if (_audioRecorder == null) throw Exception('Recording not started');
    assert(_file == null);
    assert(_length == Duration.zero);

    if (await _audioRecorder!.isPaused()) {
      await _audioRecorder!.resume();
      _stopwatch.start();
    }

    notifyListeners();
  }

  /// Cancels the current audio recording session.
  ///
  /// This method stops the recording, deletes any temporary recording files,
  /// and resets the controller state. It does not save the recorded audio.
  ///
  /// Throws an exception if not currently recording
  Future<void> cancelRecording() async {
    if (_audioRecorder == null) throw Exception('Not recording');
    assert(_file == null);
    assert(_length == Duration.zero);

    // stop the recording, deleting the temp file (if there is one)
    final path = await _audioRecorder!.stop() ?? '';
    await PlatformHelper.deleteTempAudioFile(path);

    // Clean up resources
    // unawaited(_audioRecorder!.dispose());
    // _audioRecorder = null;
    isRecording = false;
    _amplitudeStream = null;
    _startTime = null;
    _stopwatch
      ..stop()
      ..reset();

    notifyListeners();
  }

  XFile _fileFor(AudioEncoder encoder, String path) {
    final ext = _extFor(encoder);
    final mimetype = _mimeTypeFor(encoder);
    final name = kIsWeb ? 'audio.$ext' : ph.basename(path);
    return XFile(path, name: name, mimeType: mimetype);
  }

  String _extFor(AudioEncoder encoder) => switch (encoder) {
        AudioEncoder.aacLc ||
        AudioEncoder.aacEld ||
        AudioEncoder.aacHe =>
          'm4a',
        AudioEncoder.amrNb || AudioEncoder.amrWb => '3gp',
        AudioEncoder.opus => 'opus',
        AudioEncoder.flac => 'flac',
        AudioEncoder.wav => 'wav',
        AudioEncoder.pcm16bits => 'pcm',
      };

  String _mimeTypeFor(AudioEncoder encoder) => switch (encoder) {
        AudioEncoder.aacLc ||
        AudioEncoder.aacEld ||
        AudioEncoder.aacHe ||
        AudioEncoder.opus =>
          'audio/mp4',
        AudioEncoder.amrNb || AudioEncoder.amrWb => 'audio/3gpp',
        AudioEncoder.flac => 'audio/flac',
        AudioEncoder.wav => 'audio/wav',
        AudioEncoder.pcm16bits => 'audio/pcm',
      };

  /// Clears the current recording state.
  ///
  /// After calling this method, the controller will be in the same state
  /// as when it was first created, ready for a new recording.
  void clear() {
    _stopwatch.stop();
    // unawaited(_audioRecorder?.dispose());
    _file = null;
    _length = Duration.zero;
    _startTime = null;
    _amplitudeStream = null;
    // _audioRecorder = null;
        isRecording = false;

    notifyListeners();
  }
}
