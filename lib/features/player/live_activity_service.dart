import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_logger.dart';
import '../../core/ui/cover_image_source.dart';
import 'player_audio_handler.dart';
import 'player_controller.dart';

/// iOS 桌面 Widget 状态与封面同步，沿用旧 provider / MethodChannel 名称。
/// 系统媒体岛由 audio_service / NowPlaying 驱动；不再创建自定义播放活动。
final liveActivityProvider = Provider<LiveActivityService>((ref) {
  final service = LiveActivityService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// 与 `musicHomeWidgetSyncProvider` 同样的作用：声明它就开始跟随播放状态。
final liveActivitySyncProvider = Provider<void>((ref) {
  final service = ref.read(liveActivityProvider);
  ref.listen<PlayerState>(playerControllerProvider, (_, state) {
    service.publish(state);
  }, fireImmediately: true);
});

class LiveActivityService {
  LiveActivityService(this._ref);

  static const MethodChannel _channel = MethodChannel(
    'cy_shine_music/live_activity',
  );

  final Ref _ref;
  bool _available = false;
  bool _checking = false;
  bool _subscriptionsReady = false;
  String? _lastSignature;
  int _revision = 0;
  PlayerState _playerState = const PlayerState();
  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  Future<void> _queue = Future<void>.value();

  /// 桌面 Widget / 旧播放器深链请求打开播放器。
  Future<void> Function()? onOpenPlayer;

  Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    await _ensureAvailable();
  }

  /// 仅检查桌面 Widget 共享同步能力，与 ActivityKit 和通知授权无关。
  Future<void> _ensureAvailable() async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        _available ||
        _checking) {
      return;
    }
    _checking = true;
    try {
      final supported =
          await _channel.invokeMethod<bool>('isSupported') ?? false;
      if (!supported) {
        await AppLogger.write(
          'widget-sync',
          '自定义播放活动已禁用；Widget 共享容器不可用，将在播放状态变化时重试',
        );
        _available = false;
        return;
      }
      _available = true;
      _attachListeners();
      await AppLogger.write('widget-sync', '自定义播放活动已禁用；Widget 状态与封面同步已就绪');
      await _push();
    } on MissingPluginException catch (error) {
      _available = false;
      await AppLogger.write('widget-sync', '共享同步通道不可用: $error');
    } catch (error, stackTrace) {
      _available = false;
      await AppLogger.write('widget-sync', '初始化失败: $error\n$stackTrace');
    } finally {
      _checking = false;
    }
  }

  void _attachListeners() {
    if (_subscriptionsReady) return;
    _subscriptionsReady = true;
    final handler = _ref.read(playerAudioHandlerProvider);
    // 播放传输走 playbackState，曲目变化走 playerController。
    _playbackSubscription = handler.playbackState.listen(_onPlaybackState);
    // 保留时长解析后的状态同步。
    _durationSubscription = handler.durationStream.listen(
      (_) => unawaited(_push()),
    );
  }

  // MARK: - 原生回调

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'control':
        final action = call.arguments as String? ?? '';
        // 串行化，避免重复深链控制时互相打断。
        _queue = _queue
            .then((_) => _control(action))
            .catchError((Object error) async {
              await AppLogger.write('widget-sync', 'control 失败: $error');
            });
        return true;
      case 'openPlayer':
        await onOpenPlayer?.call();
        return true;
    }
    throw MissingPluginException('未知的 Widget 同步方法: ${call.method}');
  }

  Future<void> _control(String action) async {
    _ref.read(liveActivitySyncProvider);
    final player = _ref.read(playerControllerProvider.notifier);
    await player.waitForSessionRestore();
    if (!_ref.read(playerControllerProvider).hasTrack) {
      await onOpenPlayer?.call();
      return;
    }
    switch (action) {
      case 'toggle':
        await player.toggle();
      case 'previous':
        await player.playPrevious();
      case 'next':
        await player.playNext();
    }
    await AppLogger.write('widget-sync', '控制: $action');
  }

  // MARK: - 状态推送

  /// 曲目变化（可能是换歌，也可能是首次播放）。
  void publish(PlayerState state) {
    // 使用监听提供的快照，避免在 provider 通知/构建期间重读它。
    _playerState = state;
    if (!_available) {
      // 共享容器暂不可用时，在后续状态变化重试。
      unawaited(_ensureAvailable());
      return;
    }
    final track = state.track;
    if (track == null) {
      _end();
      return;
    }
    unawaited(_push());
  }

  void _onPlaybackState(PlaybackState state) {
    if (!_available) {
      unawaited(_ensureAvailable());
      return;
    }
    if (_playerState.track == null) {
      _end();
      return;
    }
    final processing = state.processingState;
    final stopped =
        processing == AudioProcessingState.idle ||
        processing == AudioProcessingState.error;
    // 停止只标记 Widget 未播放，保留上一曲标题与封面。
    if (stopped && !state.playing) {
      _end();
      return;
    }
    unawaited(_push());
  }

  /// 计算要推给桌面 Widget 的载荷；没有当前曲目时返回 null。
  Map<String, dynamic>? _payload() {
    final audioHandler = _ref.read(playerAudioHandlerProvider);
    final playback = audioHandler.playbackState.value;
    final track = _playerState.track;
    if (track == null) return null;

    final playing =
        playback.playing &&
        playback.processingState != AudioProcessingState.idle &&
        playback.processingState != AudioProcessingState.completed &&
        playback.processingState != AudioProcessingState.error;
    final loading =
        playback.processingState == AudioProcessingState.loading ||
        playback.processingState == AudioProcessingState.buffering;

    // audio_service 的 updatePosition 是「上次更新时的位置」，
    // 播放中要按经过时间补上，否则进度条会一直落后。
    var positionMs = playback.updatePosition.inMilliseconds;
    if (playing) {
      final elapsed =
          DateTime.now().difference(playback.updateTime).inMilliseconds;
      if (elapsed > 0) positionMs += elapsed;
    }
    // 时长在 MediaItem 上，不在 PlaybackState 上；而且往往播放开始后才解析出来，
    // 所以这里每次都重新读，解析到之后会通过 durationStream 再推一次更新。
    final durationMs = audioHandler.duration?.inMilliseconds ??
        audioHandler.mediaItem.value?.duration?.inMilliseconds ??
        0;
    if (positionMs < 0) positionMs = 0;
    if (durationMs > 0 && positionMs > durationMs) positionMs = durationMs;

    return {
      'trackId': track.id,
      'title': track.title,
      'artist': track.artist,
      'durationMs': durationMs,
      'positionMs': positionMs,
      'playing': playing,
      'loading': loading,
    };
  }

  Future<void> _push() async {
    if (!_available) return;
    final revision = ++_revision;
    try {
      final payload = _payload();
      if (payload == null) return;
      final track = _playerState.track!;
      payload.addAll(await _coverPayload(track));
      // 换歌/停止发生在封面缓存期间时，丢弃过期载荷。
      if (revision != _revision) return;
      final signature = jsonEncode([
        payload['trackId'],
        payload['title'],
        payload['artist'],
        payload['cover'],
        payload['headers'],
        payload['playing'],
        (payload['positionMs'] as int) ~/ 5000,
        payload['durationMs'],
      ]);
      if (_widgetSynced && signature == _lastSignature) return;
      // 兼容旧原生方法名；二者现在都只写桌面 Widget 共享状态。
      final method = _widgetSynced ? 'update' : 'start';
      // 发送后立即记录，停止若在原生回复前到达也必须发送 end。
      _lastSignature = signature;
      _widgetSynced = true;
      await _channel.invokeMethod<dynamic>(method, payload);
    } on MissingPluginException {
      _available = false;
    } catch (error) {
      if (revision == _revision) _lastSignature = null;
      await AppLogger.write('widget-sync', '同步失败: $error');
    }
  }

  bool _widgetSynced = false;

  Future<Map<String, dynamic>> _coverPayload(PlayerTrack track) async {
    try {
      final embedded = await _ref
          .read(playerAudioHandlerProvider)
          .cacheArtwork(track.coverBytes);
      final cover =
          embedded?.toString() ??
          CoverImageSource.normalizeUrl(track.coverUrl, size: 512) ??
          '';
      return {'cover': cover, 'headers': CoverImageSource.headersFor(cover) ?? {}};
    } catch (error) {
      await AppLogger.write('widget-sync', '封面处理失败: $error');
      return {'cover': '', 'headers': <String, String>{}};
    }
  }

  void _end() {
    ++_revision;
    if (!_available) return;
    final hadState = _widgetSynced;
    _widgetSynced = false;
    _lastSignature = null;
    if (!hadState) return;
    unawaited(
      _channel.invokeMethod<void>('end').catchError((Object error) async {
        await AppLogger.write('widget-sync', '标记 Widget 停止失败: $error');
      }),
    );
  }

  void dispose() {
    _end();
    unawaited(_playbackSubscription?.cancel());
    _playbackSubscription = null;
    unawaited(_durationSubscription?.cancel());
    _durationSubscription = null;
  }
}
