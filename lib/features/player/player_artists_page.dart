import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/music_api.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/app_toast.dart';
import '../discovery/widgets/discovery_playlist_cover.dart';
import '../playlists/widgets/immersive_playlist_chrome.dart';
import '../search/search_controller.dart';
import '../search/widgets/artist_result_tile.dart';
import '../shell/shell_bottom_area.dart';
import 'player_artist_resolver.dart';

void closePlaybackArtistPage(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/songs');
  }
}

class PlayerArtistsPage extends ConsumerWidget {
  const PlayerArtistsPage({super.key});

  void _search(BuildContext context, WidgetRef ref, String name) {
    final enabled = ref.read(settingsProvider).enabledSearchSources;
    if (!enabled.any(MusicApi.artistSources.contains)) {
      showAppToast(context, '请先在设置中启用歌手搜索平台', type: AppToastType.warning);
      return;
    }
    final search = ref.read(searchControllerProvider.notifier);
    search.resetToDiscovery();
    search.setCategory(SearchCategory.artists);
    final source = ref.read(playerArtistSelectionProvider)?.resolution.source;
    if (source != null &&
        enabled.contains(source) &&
        MusicApi.artistSources.contains(source)) {
      search.setSource(source);
    }
    unawaited(search.search(keyword: name));
    context.go('/');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(playerArtistSelectionProvider);
    final result = selection?.resolution;
    final artists = result?.artists ?? const [];
    final unresolved = result?.unresolvedNames ?? const <String>[];
    final scheme = Theme.of(context).colorScheme;
    final count = artists.length + unresolved.length;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(
        children: [
          ImmersivePlaylistTopBar(
            title: '歌手',
            onImage: false,
            leading: ImmersiveTopIconButton(
              tooltip: '返回播放器',
              icon: Icons.arrow_back_rounded,
              onImage: false,
              onPressed: () => closePlaybackArtistPage(context),
            ),
          ),
          PlaylistDetailInfo(
            title: selection?.request.title ?? '本曲歌手',
            metadata: '本曲歌手 · $count 位',
          ),
          Expanded(
            child: count == 0
                ? const Center(child: Text('没有可查看的歌手信息'))
                : ListView.separated(
                    key: const ValueKey('player-artists-list'),
                    padding: EdgeInsets.fromLTRB(
                      12,
                      0,
                      12,
                      ShellBottomArea.contentPadding(context, 156),
                    ),
                    itemCount: count,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      thickness: 0.7,
                      indent: 56,
                      endIndent: 4,
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                    itemBuilder: (context, index) {
                      if (index < artists.length) {
                        return ArtistResultTile(
                          artist: artists[index],
                          fromPlayback: true,
                        );
                      }
                      final name = unresolved[index - artists.length];
                      return ListTile(
                        key: ValueKey('player-artist-search-$name'),
                        minTileHeight: 62,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                        ),
                        horizontalTitleGap: 8,
                        leading: const SizedBox.square(
                          dimension: 44,
                          child: DiscoveryPlaylistCover(url: null, size: 44),
                        ),
                        title: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _search(context, ref, name),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
