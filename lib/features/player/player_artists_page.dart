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
import '../shell/shell_navigation.dart';
import '../shell/shell_route_utils.dart';
import 'player_artist_resolver.dart';

/// Remove the artist detour before reopening, so closing the player cannot
/// return to the same back button and create a navigation loop.
void returnToPlayerFromArtists(BuildContext context) {
  final selection = ProviderScope.containerOf(context, listen: false)
      .read(playerArtistSelectionProvider);
  var location = selection?.returnLocation ?? '/songs';
  final uri = Uri.tryParse(location);
  if (!isPlayerReturnLocation(location) || uri?.path == '/discover/track-artists' ||
      const ['player', 'track-artists'].contains(uri?.queryParameters['from'])) {
    location = '/';
  }
  final router = GoRouter.of(context);
  router.go(location);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final navigatorContext = router.routerDelegate.navigatorKey.currentContext;
    if (navigatorContext != null && navigatorContext.mounted) {
      openPlayer(navigatorContext, returnLocation: location);
    }
  });
}

class ArtistNavigationBack extends StatelessWidget {
  const ArtistNavigationBack({super.key, required this.location,
    required this.onBack, required this.child});
  final String location;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    bool active() => GoRouter.of(context)
        .routeInformationProvider.value.uri.path == location;
    return BackButtonListener(
      onBackButtonPressed: () async {
        if (!active()) return false;
        onBack();
        return true;
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && active()) onBack();
        },
        child: child,
      ),
    );
  }
}

class PlayerArtistsPage extends ConsumerWidget {
  const PlayerArtistsPage({super.key});

  void _returnToPlayer(BuildContext context) {
    returnToPlayerFromArtists(context);
  }

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
    if (source != null && enabled.contains(source) && MusicApi.artistSources.contains(source)) {
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
    return ArtistNavigationBack(
      location: '/discover/track-artists',
      onBack: () => _returnToPlayer(context),
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: Column(children: [
          ImmersivePlaylistTopBar(
            title: '歌手', onImage: false,
            leading: ImmersiveTopIconButton(tooltip: '返回播放器',
              icon: Icons.arrow_back_rounded, onImage: false,
              onPressed: () => _returnToPlayer(context)),
          ),
          PlaylistDetailInfo(title: selection?.request.title ?? '本曲歌手',
            metadata: '本曲歌手 · $count 位'),
          Expanded(child: count == 0
              ? const Center(child: Text('没有可查看的歌手信息'))
              : ListView.separated(
                  key: const ValueKey('player-artists-list'),
                  padding: EdgeInsets.fromLTRB(12, 0, 12,
                    ShellBottomArea.contentPadding(context, 156)),
                  itemCount: count,
                  separatorBuilder: (_, _) => Divider(height: 1, thickness: 0.7,
                    indent: 56, endIndent: 4,
                    color: scheme.outlineVariant.withValues(alpha: 0.3)),
                  itemBuilder: (context, index) {
                    if (index < artists.length) {
                      return ArtistResultTile(artist: artists[index], from: 'track-artists');
                    }
                    final name = unresolved[index - artists.length];
                    return ListTile(
                      key: ValueKey('player-artist-search-$name'), minTileHeight: 62,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      horizontalTitleGap: 8,
                      leading: const SizedBox.square(dimension: 44,
                        child: DiscoveryPlaylistCover(url: null, size: 44)),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _search(context, ref, name),
                    );
                  },
                )),
        ]),
      ),
    );
  }
}
