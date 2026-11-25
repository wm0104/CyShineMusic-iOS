import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_session/audio_session.dart';
import 'package:bass_player/bass_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cy_shine_music/features/player/player_audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared playback skips Android focus and enables iOS mixing', () {
    expect(
      shouldActivatePlayerAudioSession(
        allowMixWithOthers: false,
        isAndroid: true,
      ),
      isTrue,
    );
    expect(
      shouldActivatePlayerAudioSession(
        allowMixWithOthers: true,
        isAndroid: true,
      ),
      isFalse,
    );
    expect(
      shouldActivatePlayerAudioSession(
        allowMixWithOthers: true,
        isAndroid: false,
      ),
      isTrue,
    );

    final configuration = playerAudioSessionConfiguration(
      allowMixWithOthers: true,
    );
    expect(
      configuration.avAudioSessionCategoryOptions,
      AVAudioSessionCategoryOptions.mixWithOthers,
    );
    expect(
      configuration.androidAudioAttributes?.contentType,
      AndroidAudioContentType.music,
    );
    expect(
      configuration.androidAudioAttributes?.usage,
      AndroidAudioUsage.media,
    );
  });

  test('a stalled load fails within a bounded time instead of hanging', () {
    expect(playerLoadTimeout, greaterThan(Duration.zero));
    expect(playerLoadTimeout, lessThanOrEqualTo(const Duration(minutes: 1)));
    expect(
      const PlayerLoadTimeoutException(Duration(seconds: 40)).toString(),
      contains('40'),
    );
  });

  test('platform failures preserve signed BASS error codes', () {
    final error = BassPlayerException.fromPlatform(
      PlatformException(
        code: 'BASS_-2',
        message: 'cancelled',
        details: const {'operation': 'load', 'bassCode': -2},
      ),
    );
    expect(error.code, -2);
    expect(error.operation, 'load');
  });

  testWidgets(
    'track transition keeps the media session alive with new metadata',
    (tester) async {
      expect(playerAudioServiceConfig.androidStopForegroundOnPause, isFalse);

      final handler = PlayerAudioHandler();
      final states = <PlaybackState>[];
      final subscription = handler.playbackState.listen(states.add);
      addTearDown(() async {
        await subscription.cancel();
        unawaited(handler.disposeHandler());
      });

      handler.updateMediaMetadata(
        MediaItem(
          id: 'old',
          title: '上一首',
          artist: '旧歌手',
          duration: const Duration(minutes: 3),
          artUri: Uri.parse('https://p1.music.126.net/old.jpg'),
          artHeaders: const {'Referer': 'https://music.163.com/'},
        ),
      );
      await tester.pump();
      expect(handler.mediaItem.value?.artHeaders, {
        'Referer': 'https://music.163.com/',
      });
      final stateCountBeforeTransition = states.length;

      await handler.beginTrackTransition(
        item: const MediaItem(id: 'next', title: '下一首', artist: '新歌手'),
        queueIndex: 1,
      );
      await tester.pump();

      expect(handler.mediaItem.value?.id, 'next');
      expect(handler.mediaItem.value?.title, '下一首');
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.updatePosition, Duration.zero);
      expect(handler.playbackState.value.queueIndex, 1);
      expect(
        states
            .skip(stateCountBeforeTransition)
            .every(
              (state) => state.processingState != AudioProcessingState.idle,
            ),
        isTrue,
      );

      await handler.play();
      await handler.seek(const Duration(seconds: 30));
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.loading,
      );

      handler.failTrackTransition('加载失败');
      expect(handler.mediaItem.value?.title, '上一首');
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(handler.playbackState.value.errorMessage, contains('加载失败'));
      expect(tester.takeException(), isNull);
    },
  );

  test('system media clicks dispatch against the live BASS state', () async {
    final player = _FakeBassPlayer()..isPlaying = true;
    final handler = PlayerAudioHandler(player: player);
    var previousCount = 0;
    var nextCount = 0;
    handler.bindTransportCallbacks(
      owner: handler,
      onPrevious: () async => previousCount++,
      onNext: () async => nextCount++,
      onQueueItem: (_) async {},
      onRepeatMode: (_) async {},
      onShuffleMode: (_) async {},
    );
    addTearDown(handler.disposeHandler);

    await handler.click(MediaButton.media);
    expect(player.pauseCount, 1);
    await handler.click(MediaButton.media);
    expect(player.playCount, 1);
    await handler.click(MediaButton.next);
    await handler.click(MediaButton.previous);
    expect(nextCount, 1);
    expect(previousCount, 1);
  });

  for (final (caseName, liveState, playing) in [
    ('playing', BassProcessingState.ready, true),
    ('paused', BassProcessingState.ready, false),
    ('buffering', BassProcessingState.buffering, true),
  ]) {
    test(
      'iOS sends fresh clock anchors before lyrics and artwork while $caseName',
      () async {
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(
          () => debugDefaultTargetPlatformOverride = previousPlatform,
        );
        const channel = MethodChannel(
          'com.ryanheise.audio_service.handler.methods',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final player = _ClockBassPlayer();
        final handler = PlayerAudioHandler(player: player);
        final adapter = IosAudioServiceAdapter(() => handler);
        final updates = <String>[];
        final states = <Map<dynamic, dynamic>>[];
        final oldStateSent = Completer<void>();
        final releaseOldState = Completer<void>();
        var nativePosition = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          if (call.method == 'setState') {
            final state = args['state'] as Map;
            states.add(state);
            nativePosition = state['updatePosition'] as int;
            updates.add('position=$nativePosition');
            if (nativePosition == 234000) {
              oldStateSent.complete();
              await releaseOldState.future;
            }
          } else if (call.method == 'setMediaItem') {
            final item = args['mediaItem'] as Map;
            final hasArt = (item['extras'] as Map?)?['artCacheFile'] != null;
            updates.add(
              'title=${item['title']} at $nativePosition art=$hasArt',
            );
          }
          return null;
        });
        addTearDown(() async {
          if (!releaseOldState.isCompleted) releaseOldState.complete();
          messenger.setMockMethodCallHandler(channel, null);
          await handler.disposeHandler();
        });

        const item = MediaItem(id: 'track', title: '歌曲');
        handler.updateMediaMetadata(item);

        player.report(const Duration(seconds: 234));
        final sendingOldState = adapter.setState(
          _stateRequest(handler.playbackState.value),
        );
        await oldStateSent.future;
        player.report(const Duration(seconds: 240));
        const lyric = MediaItemMessage(id: 'track', title: '下一行歌词');
        final sendingLyric = adapter.setMediaItem(
          const SetMediaItemRequest(mediaItem: lyric),
        );
        final sendingQueuedState = adapter.setState(
          _stateRequest(handler.playbackState.value),
        );
        player.report(
          const Duration(seconds: 260),
          state: liveState,
          playing: playing,
          notify: caseName != 'playing',
        );
        await Future<void>.delayed(Duration.zero);
        expect(updates, ['position=234000']);

        releaseOldState.complete();
        await Future.wait([sendingOldState, sendingLyric, sendingQueuedState]);
        expect(updates, [
          'position=234000',
          'position=260000',
          'title=下一行歌词 at 260000 art=false',
          'position=260000',
        ]);

        final artworkPosition = caseName == 'playing' ? 282 : 260;
        player.report(
          Duration(seconds: artworkPosition),
          state: liveState,
          playing: playing,
          notify: false,
        );
        await adapter.setMediaItem(
          const SetMediaItemRequest(
            mediaItem: MediaItemMessage(
              id: 'track',
              title: '下一行歌词',
              extras: {'artCacheFile': '/cover.jpg'},
            ),
          ),
        );
        expect(updates.skip(4), [
          'position=${artworkPosition * 1000}',
          'title=下一行歌词 at ${artworkPosition * 1000} art=true',
        ]);
        for (final state in states.skip(1)) {
          expect(state['playing'], playing);
          expect(
            state['processingState'],
            liveState == BassProcessingState.buffering
                ? AudioProcessingStateMessage.buffering.index
                : AudioProcessingStateMessage.ready.index,
          );
          expect(
            state['speed'],
            liveState == BassProcessingState.buffering ? 0 : 1,
          );
          expect(
            (state['controls'] as List).map((item) => (item as Map)['action']),
            contains((playing ? MediaAction.pause : MediaAction.play).index),
          );
        }
      },
    );
  }

  test(
    'iOS keeps queued playback states tied to their original track',
    () async {
      const channel = MethodChannel(
        'com.ryanheise.audio_service.handler.methods',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final player = _ClockBassPlayer();
      final handler = PlayerAudioHandler(player: player);
      final adapter = IosAudioServiceAdapter(() => handler);
      final updates = <(int, int)>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final state = (call.arguments as Map)['state'] as Map;
        updates.add((
          state['processingState'] as int,
          state['updatePosition'] as int,
        ));
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await handler.disposeHandler();
      });

      handler.updateMediaMetadata(const MediaItem(id: 'old', title: '旧曲'));
      player.report(const Duration(seconds: 234));
      await adapter.setState(_stateRequest(handler.playbackState.value));
      player.report(const Duration(seconds: 240));
      final olderTrack = _stateRequest(handler.playbackState.value);

      const next = MediaItem(id: 'new', title: '新曲');
      await handler.beginTrackTransition(item: next);
      final loading = _stateRequest(handler.playbackState.value);
      player.report(const Duration(seconds: 12), notify: false);
      await handler.load(
        item: next,
        sourceUri: Uri.https('example.invalid', 'new'),
      );
      final ready = _stateRequest(handler.playbackState.value);

      await adapter.setState(olderTrack);
      await adapter.setState(loading);
      await adapter.setState(ready);
      expect(updates, [
        (AudioProcessingStateMessage.ready.index, 234000),
        (AudioProcessingStateMessage.loading.index, 0),
        (AudioProcessingStateMessage.ready.index, 12000),
      ]);
    },
  );

  test(
    'iOS media clock freezes while buffering and keeps seek and track changes',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
      final player = _ClockBassPlayer();
      final handler = PlayerAudioHandler(player: player);
      addTearDown(handler.disposeHandler);
      const item = MediaItem(id: 'track', title: '歌曲');
      handler.updateMediaMetadata(item);
      player.report(const Duration(seconds: 203));
      expect(handler.playbackState.value.updatePosition.inSeconds, 203);

      player.report(
        const Duration(seconds: 235),
        state: BassProcessingState.buffering,
      );
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.buffering,
      );
      expect(handler.playbackState.value.updatePosition.inSeconds, 235);
      expect(handler.playbackState.value.speed, 0);

      player.report(const Duration(seconds: 236));
      expect(handler.playbackState.value.speed, 1);
      await handler.seek(const Duration(seconds: 260));
      expect(handler.playbackState.value.updatePosition.inSeconds, 260);
      await handler.beginTrackTransition(
        item: const MediaItem(id: 'next-track', title: '下一首'),
      );
      expect(handler.playbackState.value.updatePosition, Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.mediaItem.value?.id, 'next-track');
    },
  );

  test('pause cancels a play waiting for audio session setup', () async {
    final player = _FakeBassPlayer();
    final handler = _DelayedSessionAudioHandler(player);
    addTearDown(handler.disposeHandler);

    final pendingPlay = handler.play();
    await handler.sessionSetupStarted.future;
    await handler.pause();
    handler.sessionSetupCompleted.complete();
    await pendingPlay;

    expect(player.playCount, 0);
    expect(player.isPlaying, isFalse);
    await handler.play();
    expect(player.playCount, 1);
  });

  test('pause during an interruption cancels automatic resume', () async {
    final player = _FakeBassPlayer()..isPlaying = true;
    final handler = PlayerAudioHandler(player: player);
    addTearDown(handler.disposeHandler);
    final begin = AudioInterruptionEvent(true, AudioInterruptionType.pause);
    final end = AudioInterruptionEvent(false, AudioInterruptionType.pause);

    await handler.handleAudioInterruption(begin);
    expect(player.isPlaying, isFalse);
    await handler.handleAudioInterruption(end);
    expect(player.playCount, 1);

    await handler.handleAudioInterruption(begin);
    await handler.pause();
    await handler.handleAudioInterruption(end);
    expect(player.playCount, 1);
    expect(player.isPlaying, isFalse);
  });

  test('pause cancels interruption resume while volume is restoring', () async {
    final player = _FakeBassPlayer()..isPlaying = true;
    final handler = PlayerAudioHandler(player: player);
    addTearDown(handler.disposeHandler);
    await handler.handleAudioInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await handler.handleAudioInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );

    final restoredVolume = Completer<void>();
    player.volumeRestore = restoredVolume;
    final pendingResume = handler.handleAudioInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await handler.pause();
    restoredVolume.complete();
    await pendingResume;

    expect(player.playCount, 0);
    expect(player.isPlaying, isFalse);
  });
}

SetStateRequest _stateRequest(PlaybackState state) => SetStateRequest(
  state: PlaybackStateMessage(
    playing: state.playing,
    processingState:
        AudioProcessingStateMessage.values[state.processingState.index],
    updatePosition: state.updatePosition,
    updateTime: state.updateTime,
  ),
);

class _DelayedSessionAudioHandler extends PlayerAudioHandler {
  _DelayedSessionAudioHandler(BassPlayer player) : super(player: player);

  final sessionSetupStarted = Completer<void>();
  final sessionSetupCompleted = Completer<void>();

  @override
  Future<void> setAllowMixWithOthers(bool value) async {
    if (!sessionSetupStarted.isCompleted) sessionSetupStarted.complete();
    await sessionSetupCompleted.future;
  }
}

class _FakeBassPlayer extends BassPlayer {
  bool isPlaying = false;
  int playCount = 0;
  int pauseCount = 0;
  Completer<void>? volumeRestore;

  @override
  bool get playing => isPlaying;

  @override
  Future<void> play() async {
    playCount++;
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    isPlaying = false;
  }

  @override
  Future<void> setVolume(double volume) async {
    if (volume == 1) await volumeRestore?.future;
  }

  @override
  Future<void> dispose() async {}
}

class _ClockBassPlayer extends _FakeBassPlayer {
  final _events = StreamController<BassPlaybackSnapshot>.broadcast(sync: true);
  BassPlaybackSnapshot _snapshot = const BassPlaybackSnapshot.idle();

  @override
  Stream<BassPlaybackSnapshot> get playbackEventStream => _events.stream;

  @override
  BassPlaybackSnapshot get snapshot => _snapshot;

  @override
  Duration get position => _snapshot.position;

  @override
  BassProcessingState get processingState => _snapshot.processingState;

  void report(
    Duration position, {
    BassProcessingState state = BassProcessingState.ready,
    bool playing = true,
    bool notify = true,
  }) {
    isPlaying = playing;
    _snapshot = BassPlaybackSnapshot(
      position: position,
      playing: playing,
      processingState: state,
      bufferedPosition: position,
      duration: const Duration(minutes: 5),
    );
    if (notify) _events.add(_snapshot);
  }

  @override
  Future<void> seek(Duration position) async => report(position);

  @override
  Future<BassEngineInfo> initialize() async =>
      const BassEngineInfo(version: 'fake', fxVersion: 'fake', plugins: {});

  @override
  Future<Duration?> load(
    Uri source, {
    Map<String, String> headers = const {},
    String? formatHint,
  }) async => _snapshot.duration;

  @override
  Future<void> dispose() => _events.close();
}
