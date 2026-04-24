import 'dart:async';
import 'dart:io';

import '../domain/audio_service.dart';
import '../domain/recording.dart';
import '../domain/audio_service_exception.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart'; // For generating unique IDs
import 'package:permission_handler/permission_handler.dart';

class RecordAudioService implements AudioService {
  RecordAudioService() {
    _audioPlayer.playerStateStream.listen((playerState) {
      // Convert just_audio's PlayerState to our custom PlayerState
      if (playerState.processingState == just_audio.ProcessingState.ready &&
          playerState.playing) {
        _playerStateController.add(PlayerState.playing);
      } else if (playerState.processingState ==
              just_audio.ProcessingState.ready &&
          !playerState.playing) {
        _playerStateController.add(PlayerState.paused);
      } else if (playerState.processingState ==
          just_audio.ProcessingState.completed) {
        _playerStateController.add(PlayerState.completed);
      } else if (playerState.processingState ==
          just_audio.ProcessingState.idle) {
        _playerStateController.add(PlayerState.stopped);
      } else {
        // Handle other states (loading, buffering) as stopped for simplicity
        _playerStateController.add(PlayerState.stopped);
      }
    });

    // Add backup completion detection using position and duration streams
    _audioPlayer.positionStream.listen((position) {
      final duration = _audioPlayer.duration;
      if (duration != null &&
          position >= duration &&
          _audioPlayer.playing &&
          !_completionSent) {
        // Only send completed once if we're actually playing and reached the end
        _completionSent = true;
        _playerStateController.add(PlayerState.completed);
      } else if (!_audioPlayer.playing) {
        // Reset completion flag when not playing
        _completionSent = false;
      }
    });
  }
  final AudioRecorder _audioRecorder = AudioRecorder();
  final just_audio.AudioPlayer _audioPlayer = just_audio.AudioPlayer();
  final Uuid _uuid = const Uuid();

  String? _currentRecordingPath;
  bool _completionSent = false;

  // Stream Controllers for exposing player state
  final StreamController<Duration?> _playbackPositionController =
      StreamController<Duration?>.broadcast();
  final StreamController<PlayerState> _playerStateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();

  @override
  Stream<Duration?> get playbackPositionStream => _audioPlayer.positionStream;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<Duration?> get durationStream => _audioPlayer.durationStream;

  @override
  Future<void> startRecording(String filePath) async {
    if (await _audioRecorder.hasPermission()) {
      _currentRecordingPath = filePath;
      await _audioRecorder.start(
        const RecordConfig(),
        path: _currentRecordingPath!,
      );
    } else {
      throw AudioServiceException('Recording permission not granted');
    }
  }

  @override
  Future<Recording> stopRecording() async {
    final path = await _audioRecorder.stop();
    if (path == null) {
      throw AudioServiceException(
        'Failed to stop recording or retrieve file path.',
      );
    }

    final duration = await _audioPlayer.setFilePath(
      path,
    ); // Get duration from just_audio
    await _audioPlayer.stop(); // Stop playback just after getting duration

    if (duration == null) {
      throw AudioServiceException('Could not get duration for recorded audio.');
    }

    return Recording(
      id: _uuid.v4(),
      filePath: path,
      durationSeconds: duration.inSeconds,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> playRecording(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw AudioServiceException('Recording file does not exist: $filePath');
      }
      // 先停止當前播放並等待狀態完全重置，使用內部停止方法避免觸發狀態事件
      await _internalStop();
      // 重置完成標誌，為新的播放做準備
      _completionSent = false;
      await _audioPlayer.setFilePath(filePath);
      await _audioPlayer.play();
    } catch (e) {
      throw AudioServiceException('Error playing recording: $e');
    }
  }

  @override
  Future<void> playRecordingsSequentially(List<String> filePaths) async {
    try {
      // 驗證所有文件都存在
      for (final filePath in filePaths) {
        final file = File(filePath);
        if (!await file.exists()) {
          throw AudioServiceException(
            'Recording file does not exist: $filePath',
          );
        }
      }

      // 創建音頻源列表
      final audioSources = filePaths
          .map((filePath) => just_audio.AudioSource.file(filePath))
          .toList();

      // 使用 setAudioSources 來順序播放（替換已棄用的 ConcatenatingAudioSource）
      await _audioPlayer.setAudioSources(audioSources);
      await _audioPlayer.play();
    } catch (e) {
      throw AudioServiceException('Error playing recordings sequentially: $e');
    }
  }

  @override
  Future<void> pausePlayback() async {
    await _audioPlayer.pause();
  }

  @override
  Future<void> stopPlayback() async {
    await _audioPlayer.stop();
    // 確保狀態完全重置
    await Future.delayed(const Duration(milliseconds: 10));
    _playerStateController.add(PlayerState.stopped); // Manually set to stopped
  }

  // 內部停止方法，不發送狀態事件，用於重置播放器
  Future<void> _internalStop() async {
    await _audioPlayer.stop();
    // 等待狀態完全重置，但不發送事件
    await Future.delayed(const Duration(milliseconds: 10));
  }

  @override
  Future<void> setFilePath(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw AudioServiceException('Audio file does not exist: $filePath');
    }
    // 先停止當前播放，確保狀態清潔，使用內部停止方法避免觸發狀態事件
    await _internalStop();
    await _audioPlayer.setFilePath(filePath);
  }

  @override
  Future<void> deleteAudioFile(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<bool> hasRecordingPermission() async {
    return await _audioRecorder.hasPermission();
  }

  @override
  Future<bool> requestRecordingPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  @override
  Future<String> getRecordingFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    final String uuid = _uuid.v4();
    return '${directory.path}/$uuid.m4a'; // Using m4a for good quality and small size
  }

  void dispose() {
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _playbackPositionController.close();
    _playerStateController.close();
    _durationController.close();
  }
}
