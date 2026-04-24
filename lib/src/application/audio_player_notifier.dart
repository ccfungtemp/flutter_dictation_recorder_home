import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:developer' as developer; // Import for logging
import 'package:collection/collection.dart';
import '../domain/audio_player_state.dart';
import '../domain/audio_service.dart';

import 'providers.dart';

class AudioPlayerNotifier extends Notifier<AudioPlayerState> {
  late AudioService _audioService;

  @override
  AudioPlayerState build() {
    _audioService = ref.watch(audioServiceProvider);

    _audioService.playerStateStream.listen((playerState) async {
      developer.log('AudioPlayerNotifier: PlayerState changed to $playerState');
      try {
        // Handle playback completion
        if (playerState == PlayerState.completed) {
          developer.log('AudioPlayerNotifier: Detected PlayerState.completed');
          // Update player state first
          state = state.copyWith(playerState: playerState);
          // If in sequential playing mode, all recordings have been played
          if (state.isSequentialPlaying) {
            developer.log('AudioPlayerNotifier: Sequential playback completed');
            state = state.copyWith(
              playerState: PlayerState.stopped,
              playingFilePath: null,
              currentDictationId: null,
              currentRecordingIndex: null,
              isSequentialPlaying: false,
            );
          } else if (!state.isSequentialPlaying) {
            // Single recording completed, stop
            state = state.copyWith(
              playerState: PlayerState.stopped,
              playingFilePath: null,
              currentDictationId: null,
              currentRecordingIndex: null,
            );
          }
        } else if (playerState == PlayerState.stopped) {
          developer.log('AudioPlayerNotifier: Detected PlayerState.stopped');
          state = state.copyWith(
            playerState: playerState,
            playingFilePath: null,
            currentDictationId: null,
            currentRecordingIndex: null,
          );
        } else {
          developer.log(
            'AudioPlayerNotifier: Detected PlayerState.playing/paused. Current state: $state',
          );
          state = state.copyWith(playerState: playerState);
        }
      } catch (e, stackTrace) {
        developer.log(
          'AudioPlayerNotifier: Error in playerStateStream listener: $e\n$stackTrace',
        );
        state = state.copyWith(
          playerState: PlayerState.stopped,
          playingFilePath: null,
          currentDictationId: null,
          currentRecordingIndex: null,
          isSequentialPlaying: false,
        );
      }
    });

    return const AudioPlayerState();
  }

  Future<void> _playRecording(
    String dictationId,
    int recordingIndex,
    String filePath,
  ) async {
    try {
      developer.log(
        'AudioPlayerNotifier: _playRecording called for Dictation ID: $dictationId, Index: $recordingIndex, File: $filePath',
      );
      // 不再需要手動停止，因為 playRecording 會處理

      state = state.copyWith(
        playingFilePath: filePath,
        currentDictationId: dictationId,
        currentRecordingIndex: recordingIndex,
        playerState: PlayerState.playing,
      );
      await _audioService.playRecording(filePath);
    } catch (e, stackTrace) {
      developer.log(
        'AudioPlayerNotifier: Error in _playRecording: $e\n$stackTrace',
      );
      // 播放失敗時停止並重置狀態
      state = state.copyWith(
        playerState: PlayerState.stopped,
        playingFilePath: null,
        currentDictationId: null,
        currentRecordingIndex: null,
        isSequentialPlaying: false,
      );
      rethrow; // 重新拋出異常讓上層處理
    }
  }

  Future<void> playAllRecordingsSimple(
    String dictationId, {
    int startIndex = 0,
  }) async {
    try {
      developer.log(
        'AudioPlayerNotifier: playAllRecordingsSimple called for Dictation ID: $dictationId, Start Index: $startIndex',
      );
      final dictations = ref
          .read(dictationsNotifierProvider)
          .value; // Get all dictations

      if (dictations == null || dictations.isEmpty) {
        throw Exception('No dictations available');
      }

      final dictation = dictations.firstWhereOrNull((d) => d.id == dictationId);

      if (dictation != null && dictation.recordings.isNotEmpty) {
        if (startIndex < dictation.recordings.length) {
          // 獲取從 startIndex 開始的所有文件路徑
          final filePaths = dictation.recordings
              .sublist(startIndex)
              .map((recording) => recording.filePath)
              .toList();

          // 更新狀態
          state = state.copyWith(
            playingFilePath: filePaths.first, // 第一個文件
            currentDictationId: dictationId,
            currentRecordingIndex: startIndex,
            playerState: PlayerState.playing,
            isSequentialPlaying: true, // 標記為順序播放模式
          );

          // 使用簡單的順序播放方法
          await _audioService.playRecordingsSequentially(filePaths);
        }
      } else {
        throw Exception('Dictation not found or has no recordings');
      }
    } catch (e, stackTrace) {
      developer.log(
        'AudioPlayerNotifier: Error in playAllRecordingsSimple: $e\n$stackTrace',
      );
      state = state.copyWith(
        playerState: PlayerState.stopped,
        playingFilePath: null,
        currentDictationId: null,
        currentRecordingIndex: null,
        isSequentialPlaying: false,
      );
      rethrow;
    }
  }

  /// 播放單個錄音，不進入順序播放模式
  Future<void> playSingleRecording(
    String dictationId,
    int recordingIndex,
  ) async {
    developer.log(
      'AudioPlayerNotifier: playSingleRecording called for Dictation ID: $dictationId, Index: $recordingIndex',
    );
    final dictations = ref
        .read(dictationsNotifierProvider)
        .value; // Get all dictations
    final dictation = dictations?.firstWhereOrNull((d) => d.id == dictationId);

    if (dictation != null &&
        recordingIndex >= 0 &&
        recordingIndex < dictation.recordings.length) {
      state = state.copyWith(isSequentialPlaying: false);
      await _playRecording(
        dictationId,
        recordingIndex,
        dictation.recordings[recordingIndex].filePath,
      );
    }
  }

  Future<void> playNext() async {
    developer.log(
      'AudioPlayerNotifier: playNext called. Current state: $state',
    );
    if (state.currentDictationId == null ||
        state.currentRecordingIndex == null) {
      return;
    }

    final dictations = ref.read(dictationsNotifierProvider).value;
    final currentDictation = dictations?.firstWhereOrNull(
      (d) => d.id == state.currentDictationId,
    );

    if (currentDictation != null) {
      final nextIndex = state.currentRecordingIndex! + 1;
      if (nextIndex < currentDictation.recordings.length) {
        await _playRecording(
          currentDictation.id,
          nextIndex,
          currentDictation.recordings[nextIndex].filePath,
        );
      } else {
        // Reached end of recordings, stop playback
        developer.log(
          'AudioPlayerNotifier: playNext reached end of recordings. Stopping.',
        );
        await stop();
      }
    }
  }

  Future<void> playPrevious() async {
    developer.log(
      'AudioPlayerNotifier: playPrevious called. Current state: $state',
    );
    if (state.currentDictationId == null ||
        state.currentRecordingIndex == null) {
      return;
    }

    final dictations = ref.read(dictationsNotifierProvider).value;
    final currentDictation = dictations?.firstWhereOrNull(
      (d) => d.id == state.currentDictationId,
    );

    if (currentDictation != null) {
      final previousIndex = state.currentRecordingIndex! - 1;
      if (previousIndex >= 0) {
        await _playRecording(
          currentDictation.id,
          previousIndex,
          currentDictation.recordings[previousIndex].filePath,
        );
      } else {
        // Reached beginning of recordings, stay on first or stop
        developer.log(
          'AudioPlayerNotifier: playPrevious reached beginning of recordings. Stopping.',
        );
        await stop(); // Or stay on the first recording
      }
    }
  }

  Future<void> pause() async {
    developer.log('AudioPlayerNotifier: pause called. Current state: $state');
    await _audioService.pausePlayback();
    // 暫停時不改變isSequentialPlaying，這樣resume時才能繼續順序播放
    state = state.copyWith(playerState: PlayerState.paused);
  }

  Future<void> resume() async {
    developer.log('AudioPlayerNotifier: resume called. Current state: $state');
    // If paused, just resume current playback
    if (state.playerState == PlayerState.paused &&
        state.playingFilePath != null) {
      await _audioService.playRecording(state.playingFilePath!);
      // 恢復時保留isSequentialPlaying的值
      state = state.copyWith(playerState: PlayerState.playing);
    } else if (state.playerState == PlayerState.stopped &&
        state.currentDictationId != null &&
        state.isSequentialPlaying) {
      // If stopped but in sequential mode, restart from current index
      developer.log(
        'AudioPlayerNotifier: resume from stopped state with sequential mode. Starting from index ${state.currentRecordingIndex ?? 0}',
      );
      await playAllRecordingsSimple(
        state.currentDictationId!,
        startIndex: state.currentRecordingIndex ?? 0,
      );
    }
  }

  Future<void> stop() async {
    developer.log('AudioPlayerNotifier: stop called. Current state: $state');
    await _audioService.stopPlayback();
    state = state.copyWith(
      playerState: PlayerState.stopped,
      playingFilePath: null,
      currentDictationId: null,
      currentRecordingIndex: null,
      isSequentialPlaying: false,
    );
  }

  // New method to set the current recording without starting playback
  Future<void> setCurrentRecording(
    String dictationId,
    int recordingIndex,
  ) async {
    developer.log(
      'AudioPlayerNotifier: setCurrentRecording called for Dictation ID: $dictationId, Index: $recordingIndex. Current state: $state',
    );
    final dictations = ref.read(dictationsNotifierProvider).value;
    final dictation = dictations?.firstWhereOrNull((d) => d.id == dictationId);

    if (dictation != null && dictation.recordings.isNotEmpty) {
      if (recordingIndex >= 0 && recordingIndex < dictation.recordings.length) {
        state = state.copyWith(
          playingFilePath: dictation.recordings[recordingIndex].filePath,
          currentDictationId: dictationId,
          currentRecordingIndex: recordingIndex,
          playerState:
              PlayerState.stopped, // Set to stopped as it's not playing
        );
        // Preload the audio file to allow for quick playback if user presses play
        await _audioService.setFilePath(
          dictation.recordings[recordingIndex].filePath,
        );
        developer.log(
          'AudioPlayerNotifier: setCurrentRecording updated state: $state',
        );
      }
    }
  }
}
