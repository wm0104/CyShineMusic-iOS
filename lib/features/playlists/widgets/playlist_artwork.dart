import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/embedded_artwork_cache.dart';
import '../../../core/ui/cover_image_source.dart';
import '../playlist_cover_image.dart';
import '../playlist_cover_resolver.dart';
import '../playlist_models.dart';
import 'immersive_playlist_chrome.dart'
    show PlaylistArtworkImage, networkPlaylistArtworkProvider;

// 手建歌单与在线、洛雪导入在存储中使用不同的 ID 前缀。
bool usesManualPlaylistArtwork(LocalPlaylist playlist) =>
    playlist.id.startsWith('local-') &&
    playlist.originPlaylistId == null &&
    playlist.originSourceCode == null &&
    playlist.coverUrl?.trim().isNotEmpty != true;

/// 歌单封面回退来源：第一个带封面来源（网络图或本地文件）的曲目。
///
/// 只取第一个候选、不级联尝试后续曲目，避免歌单列表一次性
/// 触发大量内嵌封面读盘（[EmbeddedArtworkCache] 并发上限为 2）。
PlaylistTrack? playlistCoverFallbackTrack(LocalPlaylist playlist) {
  for (final track in playlist.tracks) {
    if (track.picUrl?.trim().isNotEmpty == true || track.isLocal) {
      return track;
    }
  }
  return null;
}

class PlaylistCover extends StatelessWidget {
  const PlaylistCover({
    super.key,
    required this.playlist,
    required this.size,
    required this.radius,
    required this.placeholder,
  });

  final LocalPlaylist playlist;
  final double size;
  final double radius;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    if (usesManualPlaylistArtwork(playlist)) {
      return SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: ManualPlaylistArtworkBuilder(
            playlist: playlist,
            imageSize: (size * 3).round(),
            builder: (context, images) => PlaylistArtworkComposition(
              images: images,
              placeholder: placeholder,
            ),
          ),
        ),
      );
    }
    final coverUrl = playlist.coverUrl?.trim();
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return PlaylistCoverImage(
        url: coverUrl,
        size: size,
        radius: radius,
        placeholder: placeholder,
      );
    }
    final fallback = playlistCoverFallbackTrack(playlist);
    if (fallback == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: placeholder,
      );
    }
    return PlaylistTrackArtwork(
      localPath: fallback.localPath,
      picUrl: fallback.picUrl,
      size: size,
      radius: radius,
      placeholder: placeholder,
    );
  }
}

/// Resolves only the first four tracks in the playlist's saved order.
class ManualPlaylistArtworkBuilder extends StatefulWidget {
  const ManualPlaylistArtworkBuilder({
    super.key,
    required this.playlist,
    required this.imageSize,
    required this.builder,
  });

  final LocalPlaylist playlist;
  final int imageSize;
  final Widget Function(BuildContext, List<ImageProvider<Object>?>) builder;

  @override
  State<ManualPlaylistArtworkBuilder> createState() =>
      _ManualPlaylistArtworkBuilderState();
}

typedef _ArtworkSource = ({String? localPath, ImageProvider<Object>? network});

class _ManualPlaylistArtworkBuilderState
    extends State<ManualPlaylistArtworkBuilder> {
  List<_ArtworkSource> _sources = const [];
  ImageConfiguration? _configuration;
  int? _imageSize;
  List<_ArtworkCandidate> _candidates = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCandidates();
  }

  @override
  void didUpdateWidget(covariant ManualPlaylistArtworkBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.playlist, oldWidget.playlist) ||
        widget.imageSize != oldWidget.imageSize) {
      _updateCandidates();
    }
  }

  @override
  void dispose() {
    for (final candidate in _candidates) {
      candidate.dispose();
    }
    super.dispose();
  }

  void _updateCandidates() {
    final playlist = widget.playlist;
    final tracks = playlist.customTrackOrder == null
        ? playlist.tracks
        : playlist.customOrderedTracks;
    final size = widget.imageSize;
    final configuration = createLocalImageConfiguration(context);
    final sources = [
      for (final track in tracks.take(4))
        (
          localPath: track.localPath?.trim(),
          network: CoverImageSource.isUsableUrl(track.picUrl)
              ? networkPlaylistArtworkProvider(track.picUrl, size: size)
              : null,
        ),
    ];
    if (_configuration == configuration &&
        _imageSize == size &&
        listEquals(_sources, sources)) {
      return;
    }
    for (final candidate in _candidates) {
      candidate.dispose();
    }
    _sources = sources;
    _configuration = configuration;
    _imageSize = size;
    _candidates = [
      for (final source in sources)
        _ArtworkCandidate(source, configuration, size, () => setState(() {})),
    ];
    for (final candidate in _candidates) {
      candidate.load();
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, [
    for (final candidate in _candidates) candidate.image,
  ]);
}

class _ArtworkCandidate {
  _ArtworkCandidate(this.source, this.configuration, this.size, this.onLoad);

  final _ArtworkSource source;
  final ImageConfiguration configuration;
  final int size;
  final VoidCallback onLoad;
  ImageProvider<Object>? image;
  EmbeddedArtworkRequest? _embedded;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  void load() {
    final path = source.localPath;
    if (path == null || path.isEmpty) {
      _loadNetwork();
      return;
    }
    final request = EmbeddedArtworkCache.subscribe(path);
    _embedded = request;
    unawaited(
      request.future.then((bytes) {
        if (!identical(_embedded, request)) return;
        _embedded = null;
        request.cancel();
        if (bytes == null || bytes.isEmpty) {
          _loadNetwork();
        } else {
          _loadImage(MemoryImage(bytes), onError: _loadNetwork);
        }
      }),
    );
  }

  void _loadNetwork() {
    final provider = source.network;
    if (provider != null) _loadImage(provider);
  }

  void _loadImage(ImageProvider<Object> source, {VoidCallback? onError}) {
    final provider = ResizeImage(
      source,
      width: size,
      height: size,
      policy: ResizeImagePolicy.fit,
    );
    final stream = provider.resolve(configuration);
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!identical(_stream, stream)) return;
        _detachImage();
        image = provider;
        onLoad();
      },
      onError: (_, _) {
        if (!identical(_stream, stream)) return;
        _detachImage();
        onError?.call();
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detachImage() {
    final stream = _stream;
    final listener = _listener;
    _stream = null;
    _listener = null;
    if (listener != null) stream?.removeListener(listener);
  }

  void dispose() {
    _embedded?.cancel();
    _embedded = null;
    _stream?.completer?.addEphemeralErrorListener((_, _) {});
    _detachImage();
  }
}

class PlaylistArtworkComposition extends StatelessWidget {
  const PlaylistArtworkComposition({
    super.key,
    required this.images,
    required this.placeholder,
  });

  final List<ImageProvider<Object>?> images;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    final usable = images.whereType<ImageProvider<Object>>();
    final first = usable.firstOrNull;
    if (first == null) return placeholder;
    if (usable.skip(1).isEmpty) return _buildImage(first);
    return Column(
      children: [
        for (var row = 0; row < 2; row++)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var column = 0; column < 2; column++)
                  Expanded(child: _buildCell(row * 2 + column)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCell(int index) {
    final provider = index < images.length ? images[index] : null;
    return provider == null ? placeholder : _buildImage(provider);
  }

  Widget _buildImage(ImageProvider<Object> provider) => PlaylistArtworkImage(
    provider: provider,
    loading: false,
    placeholder: placeholder,
  );
}

/// 单曲封面：本地文件内嵌封面 → 网络 `picUrl` → 占位图。
class PlaylistTrackArtwork extends StatefulWidget {
  const PlaylistTrackArtwork({
    super.key,
    required this.localPath,
    required this.picUrl,
    required this.size,
    required this.radius,
    required this.placeholder,
  });

  final String? localPath;
  final String? picUrl;
  final double size;
  final double radius;
  final Widget placeholder;

  @override
  State<PlaylistTrackArtwork> createState() => _PlaylistTrackArtworkState();
}

class ResolvingPlaylistTrackArtwork extends ConsumerWidget {
  const ResolvingPlaylistTrackArtwork({
    super.key,
    required this.playlistId,
    required this.track,
    required this.size,
    required this.radius,
    required this.placeholder,
  });

  final String playlistId;
  final PlaylistTrack track;
  final double size;
  final double radius;
  final Widget placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final normalized = CoverImageSource.normalizeUrl(
      track.picUrl,
      size: (size * 3).round(),
    );
    final storedUrl = CoverImageSource.isUsableUrl(normalized)
        ? normalized
        : null;
    AsyncValue<String?>? lookup;
    if (storedUrl == null && track.musicInfo != null) {
      lookup = ref.watch(
        playlistTrackCoverProvider(
          PlaylistTrackCoverKey(playlistId: playlistId, track: track),
        ),
      );
    }
    final resolved = lookup?.asData?.value?.trim();

    return PlaylistTrackArtwork(
      localPath: track.localPath,
      picUrl: resolved?.isNotEmpty == true ? resolved : storedUrl,
      size: size,
      radius: radius,
      placeholder: placeholder,
    );
  }
}

class _PlaylistTrackArtworkState extends State<PlaylistTrackArtwork> {
  Uint8List? _artworkBytes;
  EmbeddedArtworkRequest? _artworkRequest;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadEmbeddedArtwork();
  }

  @override
  void didUpdateWidget(covariant PlaylistTrackArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.localPath != oldWidget.localPath) {
      _loadEmbeddedArtwork();
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _artworkRequest?.cancel();
    _artworkRequest = null;
    super.dispose();
  }

  void _loadEmbeddedArtwork() {
    final generation = ++_loadGeneration;
    _artworkRequest?.cancel();
    _artworkRequest = null;
    _artworkBytes = null;
    final path = widget.localPath?.trim();
    if (path == null || path.isEmpty) return;
    final request = EmbeddedArtworkCache.subscribe(path);
    _artworkRequest = request;
    unawaited(
      request.future.then((bytes) {
        if (identical(_artworkRequest, request)) _artworkRequest = null;
        request.cancel();
        if (!mounted ||
            generation != _loadGeneration ||
            path != widget.localPath?.trim() ||
            bytes == null ||
            bytes.isEmpty) {
          return;
        }
        setState(() => _artworkBytes = bytes);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final artworkBytes = _artworkBytes;
    if (artworkBytes != null && artworkBytes.isNotEmpty) {
      final cacheSize = (widget.size * 3).round();
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: Image.memory(
          artworkBytes,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.placeholder,
        ),
      );
    }
    return PlaylistCoverImage(
      url: widget.picUrl,
      size: widget.size,
      radius: widget.radius,
      placeholder: widget.placeholder,
    );
  }
}
