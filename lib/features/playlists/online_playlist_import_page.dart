import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/playlist_info.dart';
import '../../core/sdk/internal/format.dart';
import '../../core/ui/app_toast.dart';
import '../../core/ui/car_display_layout.dart';
import '../shell/shell_bottom_area.dart';
import '../downloads/download_progress.dart';
import '../music_sources/music_source_action_guard.dart';
import '../player/player_controller.dart';
import '../search/widgets/quality_picker_sheet.dart';
import '../search/widgets/search_result_tile.dart';
import 'playlist_cover_image.dart';
import 'playlist_store.dart';
import 'spotify_playlist_import.dart';
import '../shell/shell_navigation.dart';

class _OnlinePlaylistDraft {
  const _OnlinePlaylistDraft({
    this.input = '',
    this.source = MusicSource.all,
    this.playlist,
    this.spotify,
  });

  final String input;
  final MusicSource source;
  final PlaylistInfo? playlist;
  final SpotifyPlaylistPreview? spotify;
}

final _onlinePlaylistDraftProvider = StateProvider<_OnlinePlaylistDraft>(
  (ref) => const _OnlinePlaylistDraft(),
);

class OnlinePlaylistImportPage extends ConsumerStatefulWidget {
  const OnlinePlaylistImportPage({super.key});

  @override
  ConsumerState<OnlinePlaylistImportPage> createState() =>
      _OnlinePlaylistImportPageState();
}

class _OnlinePlaylistImportPageState
    extends ConsumerState<OnlinePlaylistImportPage> {
  final TextEditingController _inputController = TextEditingController();
  MusicSource _source = MusicSource.all;
  PlaylistInfo? _playlist;
  SpotifyPlaylistPreview? _spotify;
  String? _progress;
  String? _error;
  bool _loading = false;
  bool _saving = false;
  Object? _requestToken;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(_onlinePlaylistDraftProvider);
    _inputController.text = draft.input;
    _source = draft.source;
    _playlist = draft.playlist;
    _spotify = draft.spotify;
  }

  @override
  void dispose() {
    _requestToken = null;
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spotify = _spotify;
    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: CarDisplayLayout.contentConstraints(
                    context,
                    maxWidth: 760,
                  ),
                  child: _ImportForm(
                    controller: _inputController,
                    source: _source,
                    loading: _loading,
                    onSourceChanged: (source) {
                      setState(() {
                        _source = source;
                        _playlist = null;
                        _spotify = null;
                        _error = null;
                      });
                      _rememberDraft(playlist: null);
                    },
                    onInputChanged: _handleInputChanged,
                    onClear: _clearInput,
                    onParse: _parse,
                  ),
                ),
              ),
            ),
          ),
          if (_loading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ImportLoading(message: _progress),
            )
          else if (_error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ImportError(message: _error!, onRetry: _parse),
            )
          else if (_playlist == null && spotify == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _ImportIdle(),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: CarDisplayLayout.contentConstraints(
                      context,
                      maxWidth: 760,
                    ),
                    child: _ParsedPlaylistHeader(
                      name: spotify?.name ?? _playlist!.name,
                      coverUrl: spotify != null
                          ? spotify.coverUrl
                          : _playlist!.coverUrl,
                      creator: spotify != null
                          ? spotify.creator
                          : _playlist!.creator,
                      sourceLabel: spotify != null
                          ? 'Spotify'
                          : _playlist!.source.label,
                      count: spotify?.tracks.length ?? _playlist!.tracks.length,
                      spotify: spotify,
                      saving: _saving,
                      onSave: _savePlaylist,
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                ShellBottomArea.contentPadding(context, 120),
              ),
              sliver: SliverList.separated(
                itemCount: spotify?.tracks.length ?? _playlist!.tracks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final track = spotify?.tracks[index];
                  final music = track != null
                      ? track.musicInfo
                      : _playlist!.tracks[index];
                  final durationMs = track?.spotify?.durationMs;
                  return Center(
                    child: ConstrainedBox(
                      constraints: CarDisplayLayout.contentConstraints(
                        context,
                        maxWidth: 760,
                      ),
                      child: music == null
                          ? TrackResultRow(
                              name: track!.name,
                              singer: track.singer,
                              sourceLabel: track.sourceLabel,
                              interval: durationMs == null
                                  ? null
                                  : formatPlayTime(durationMs / 1000),
                            )
                          : _OnlineTrackTile(
                              music: music,
                              displayName: track?.name,
                              displaySinger: track?.singer,
                              onDownload: () =>
                                  showQualityPickerSheet(context, music),
                              onPlay: () => _play(music),
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _parse() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      showAppToast(context, '请输入歌单链接或 ID', type: AppToastType.warning);
      return;
    }
    final request = Object();
    _requestToken = request;
    setState(() {
      _loading = true;
      _playlist = null;
      _spotify = null;
      _progress = null;
      _error = null;
    });
    _rememberDraft(playlist: null);
    try {
      final link = spotifyShareLink(input);
      if (link != null) {
        final spotify = await ref
            .read(spotifyPlaylistImporterProvider)
            .read(
              link,
              cancelled: () => !mounted || !identical(_requestToken, request),
              onProgress: (done, total) {
                if (mounted && identical(_requestToken, request)) {
                  setState(() => _progress = '正在匹配音源 · $done / $total');
                }
              },
            );
        if (!mounted || !identical(_requestToken, request)) return;
        setState(() {
          _loading = false;
          _spotify = spotify;
        });
        _rememberDraft();
        return;
      }
      final playlist = await ref
          .read(musicApiProvider)
          .parsePlaylist(input: input, source: _source);
      if (!mounted || !identical(_requestToken, request)) return;
      setState(() {
        _loading = false;
        _playlist = playlist;
      });
      _rememberDraft(playlist: playlist);
    } catch (error) {
      if (!mounted || !identical(_requestToken, request)) return;
      setState(() {
        _loading = false;
        _error = describeDioError(error);
      });
      _rememberDraft(playlist: null);
    }
  }

  Future<void> _savePlaylist() async {
    final playlist = _playlist;
    final spotify = _spotify;
    if ((playlist == null && spotify == null) || _saving) return;
    try {
      if (spotify != null && !spotify.complete) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('保存当前可见曲目？'),
            content: Text(_spotifyCountMessage(spotify)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('仅保存这 ${spotify.tracks.length} 首'),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (accepted != true) return;
      }
      setState(() => _saving = true);
      final store = ref.read(localPlaylistsProvider.notifier);
      final local = spotify != null
          ? await store.importSpotify(spotify)
          : await store.importOnline(playlist!);
      if (!mounted) return;
      showAppToast(context, '歌单已保存到本地', type: AppToastType.success);
      ref.read(_onlinePlaylistDraftProvider.notifier).state =
          const _OnlinePlaylistDraft();
      context.go(
        Uri(
          path: '/playlists/${local.id}',
          queryParameters: const {'from': 'manage'},
        ).toString(),
      );
    } catch (error) {
      if (!mounted) return;
      showAppToast(context, '保存失败：$error', type: AppToastType.error);
      setState(() => _saving = false);
    }
  }

  Future<void> _play(MusicInfo music) async {
    final available = await ensureOnlineMusicSourcesAvailable(context, [
      music.source,
    ]);
    if (!available || !mounted) return;
    openPlayer(context, returnLocation: '/playlists/import');
    await ref.read(playerControllerProvider.notifier).playFromMusic(music);
  }

  void _clearInput() {
    _requestToken = null;
    _inputController.clear();
    setState(() {
      _spotify = null;
      _playlist = null;
      _error = null;
    });
    ref.read(_onlinePlaylistDraftProvider.notifier).state =
        _OnlinePlaylistDraft(source: _source);
  }

  void _handleInputChanged(String _) {
    if (_playlist != null || _spotify != null || _error != null) {
      setState(() {
        _spotify = null;
        _playlist = null;
        _error = null;
      });
    }
    _rememberDraft(playlist: null);
  }

  void _rememberDraft({PlaylistInfo? playlist}) {
    ref
        .read(_onlinePlaylistDraftProvider.notifier)
        .state = _OnlinePlaylistDraft(
      input: _inputController.text,
      source: _source,
      playlist: playlist ?? _playlist,
      spotify: _spotify,
    );
  }
}

class _ImportForm extends StatelessWidget {
  const _ImportForm({
    required this.controller,
    required this.source,
    required this.loading,
    required this.onSourceChanged,
    required this.onInputChanged,
    required this.onClear,
    required this.onParse,
  });

  final TextEditingController controller;
  final MusicSource source;
  final bool loading;
  final ValueChanged<MusicSource> onSourceChanged;
  final ValueChanged<String> onInputChanged;
  final VoidCallback onClear;
  final VoidCallback onParse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final useVerticalLayout =
                  constraints.maxWidth < 288 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final segmentedButton = SegmentedButton<MusicSource>(
                direction: useVerticalLayout ? Axis.vertical : Axis.horizontal,
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(0, 48)),
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 10),
                  ),
                  textStyle: WidgetStatePropertyAll(
                    TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                segments: const [
                  ButtonSegment(
                    value: MusicSource.all,
                    icon: Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text('自动'),
                  ),
                  ButtonSegment(
                    value: MusicSource.kw,
                    icon: Icon(Icons.radio_rounded, size: 18),
                    label: Text('酷我'),
                  ),
                  ButtonSegment(
                    value: MusicSource.kg,
                    icon: Icon(Icons.graphic_eq_rounded, size: 18),
                    label: Text('酷狗'),
                  ),
                  ButtonSegment(
                    value: MusicSource.tx,
                    icon: Icon(Icons.headphones_rounded, size: 18),
                    label: Text('QQ'),
                  ),
                  ButtonSegment(
                    value: MusicSource.wy,
                    icon: Icon(Icons.cloud_outlined, size: 18),
                    label: Text('网易云'),
                  ),
                  ButtonSegment(
                    value: MusicSource.mg,
                    icon: Icon(Icons.library_music_rounded, size: 18),
                    label: Text('咪咕'),
                  ),
                ],
                selected: {source},
                showSelectedIcon: false,
                onSelectionChanged: loading
                    ? null
                    : (values) => onSourceChanged(values.first),
              );
              return useVerticalLayout
                  ? SizedBox(
                      width: constraints.maxWidth,
                      child: segmentedButton,
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: segmentedButton,
                    );
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            enabled: !loading,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            maxLines: 2,
            minLines: 1,
            decoration: InputDecoration(
              labelText: '歌单链接或 ID',
              hintText: '粘贴 Spotify 或其他平台的歌单链接',
              prefixIcon: const Icon(Icons.link_rounded),
              suffixIcon: IconButton(
                tooltip: '清空',
                onPressed: loading ? null : onClear,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            onChanged: onInputChanged,
            onSubmitted: (_) => onParse(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: loading ? null : onParse,
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.travel_explore_rounded),
            label: Text(loading ? '解析中' : '解析歌单'),
          ),
        ],
      ),
    );
  }
}

class _ParsedPlaylistHeader extends StatelessWidget {
  const _ParsedPlaylistHeader({
    required this.name,
    required this.coverUrl,
    required this.creator,
    required this.sourceLabel,
    required this.count,
    this.spotify,
    required this.saving,
    required this.onSave,
  });

  final String name;
  final String? coverUrl;
  final String? creator;
  final String sourceLabel;
  final int count;
  final SpotifyPlaylistPreview? spotify;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = spotify;
    final details = [
      '$count 首',
      if (creator?.trim().isNotEmpty == true) creator!.trim(),
    ].join(' · ');
    final metadata = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: sourceLabel,
            style: preview == null
                ? null
                : const TextStyle(decoration: TextDecoration.underline),
          ),
          TextSpan(text: ' · $details'),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: scheme.onPrimaryContainer.withValues(alpha: 0.76),
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _OnlinePlaylistCover(url: coverUrl),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 5),
                    if (preview == null)
                      metadata
                    else
                      Tooltip(
                        message: '在 Spotify 查看歌单',
                        child: Semantics(
                          link: true,
                          child: InkWell(
                            onTap: () => launchUrl(
                              Uri.https(
                                'open.spotify.com',
                                '/playlist/${preview.id}',
                              ),
                              mode: LaunchMode.externalApplication,
                            ),
                            child: metadata,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (preview != null) ...[
            const SizedBox(height: 8),
            Text('${preview.matched} 首已匹配音源 · ${count - preview.matched} 首未匹配'),
            if (!preview.hasMatchingPlatforms && count > 0)
              const Text('启用音源及对应的搜索平台后，可以再次导入以匹配歌曲。'),
            if (!preview.complete) Text(_spotifyCountMessage(preview)),
          ],
          const SizedBox(height: 13),
          FilledButton.icon(
            onPressed: saving ? null : onSave,
            icon: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.save_alt_rounded),
            label: Text(saving ? '保存中' : '保存到本地歌单'),
          ),
        ],
      ),
    );
  }
}

String _spotifyCountMessage(SpotifyPlaylistPreview preview) {
  final count = preview.tracks.length;
  final total = preview.total;
  if (total == null || total < count) {
    return 'Spotify 预览提供了 $count 首，无法核实歌单总数。';
  }
  return '原歌单共 $total 首，Spotify 预览仅提供 $count 首。';
}

class _OnlinePlaylistCover extends StatelessWidget {
  const _OnlinePlaylistCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: 76,
      height: 76,
      color: scheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.queue_music_rounded,
        color: scheme.onSecondaryContainer,
        size: 32,
      ),
    );
    return PlaylistCoverImage(
      url: url,
      size: 76,
      radius: 20,
      placeholder: placeholder,
    );
  }
}

class _OnlineTrackTile extends ConsumerWidget {
  const _OnlineTrackTile({
    required this.music,
    required this.onDownload,
    required this.onPlay,
    this.displayName,
    this.displaySinger,
  });

  final MusicInfo music;
  final VoidCallback onDownload;
  final VoidCallback onPlay;
  final String? displayName;
  final String? displaySinger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(
      downloadProgressProvider.select(
        (value) => value.latestTaskForMusic(music.id),
      ),
    );
    return SearchResultTile(
      music: music,
      displayName: displayName,
      displaySinger: displaySinger,
      onDownload: onDownload,
      onPlay: onPlay,
      downloadTask: task,
    );
  }
}

class _ImportLoading extends StatelessWidget {
  const _ImportLoading({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: ShellBottomArea.contentPadding(context, 108),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: scheme.primary),
          const SizedBox(height: 16),
          Text(
            message ?? '正在读取歌单',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportIdle extends StatelessWidget {
  const _ImportIdle();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: ShellBottomArea.contentPadding(context, 108),
      ),
      child: Center(
        child: Icon(
          Icons.cloud_download_outlined,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.62),
          size: 54,
        ),
      ),
    );
  }
}

class _ImportError extends StatelessWidget {
  const _ImportError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        28,
        20,
        28,
        ShellBottomArea.contentPadding(context, 108),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.link_off_rounded, color: scheme.error, size: 48),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
