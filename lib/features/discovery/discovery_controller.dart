import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/artist_info.dart';
import '../../core/models/enums.dart';
import '../../core/models/leaderboard_info.dart';
import '../../core/models/music_info.dart';
import '../../core/models/online_collection_kind.dart';
import '../../core/models/playlist_category.dart';
import '../../core/models/playlist_info.dart';
import '../../core/models/playlist_summary.dart';
import '../../core/storage/settings_store.dart';
import '../../core/ui/cover_image_source.dart';

const int discoveryPlaylistArtworkSize = 640;
const int discoveryPlaylistPageSize = 30;
const int onlinePlaylistDetailInitialTrackLimit = 40;
const int onlinePlaylistDetailTrackPageSize = 40;
final discoverySourcesProvider = Provider<List<MusicSource>>(
  (ref) => ref.watch(settingsProvider).discoverySourceOrder,
);

typedef OnlinePlaylistIdentity = ({
  MusicSource source,
  String id,
  OnlineCollectionKind kind,
});

typedef LeaderboardIdentity = ({MusicSource source, String boardId});

final onlinePlaylistSummaryCacheProvider =
    Provider<Map<OnlinePlaylistIdentity, PlaylistSummary>>((ref) => {});

// Keep the loaded range alongside the shell's saved scroll position.
final onlinePlaylistTrackLimitCacheProvider =
    Provider<Map<OnlinePlaylistIdentity, int>>((ref) => {});

String onlinePlaylistArtworkHeroTag(
  MusicSource source,
  String playlistId, {
  OnlineCollectionKind kind = OnlineCollectionKind.playlist,
}) {
  return 'online-${kind.name}-artwork:${source.code}:$playlistId';
}

final selectedDiscoverySourceProvider = StateProvider<MusicSource>(
  (ref) => ref.watch(discoverySourcesProvider).first,
);

final selectedDiscoveryCategoryProvider =
    StateProvider.family<String, MusicSource>(
      (ref, source) => defaultPlaylistCatalogCategoryFor(source).id,
    );

final featuredPlaylistsProvider =
    FutureProvider.family<List<PlaylistSummary>, MusicSource>((ref, source) {
      final categoryId = ref.watch(selectedDiscoveryCategoryProvider(source));
      return ref
          .watch(musicApiProvider)
          .featuredPlaylists(
            source: source,
            page: 1,
            limit: discoveryPlaylistPageSize,
            categoryId: categoryId,
          );
    });

final leaderboardBoardsProvider =
    FutureProvider.family<List<LeaderboardSummary>, MusicSource>((ref, source) {
      return ref.watch(musicApiProvider).getLeaderboards(source);
    });

final leaderboardPreviewProvider =
    FutureProvider.family<LeaderboardSummary, LeaderboardIdentity>((
      ref,
      key,
    ) async {
      final boards = await ref.watch(
        leaderboardBoardsProvider(key.source).future,
      );
      final board = boards.firstWhere(
        (item) => item.boardId == key.boardId,
        orElse: () => throw StateError('排行榜不存在'),
      );
      return ref.watch(musicApiProvider).getLeaderboardPreview(board);
    });

class OnlinePlaylistKey {
  const OnlinePlaylistKey({
    required this.source,
    required this.id,
    this.kind = OnlineCollectionKind.playlist,
    this.maxTracks = onlinePlaylistDetailInitialTrackLimit,
  });

  final MusicSource source;
  final String id;
  final OnlineCollectionKind kind;
  final int? maxTracks;

  @override
  bool operator ==(Object other) =>
      other is OnlinePlaylistKey &&
      other.source == source &&
      other.id == id &&
      other.kind == kind &&
      other.maxTracks == maxTracks;

  @override
  int get hashCode => Object.hash(source, id, kind, maxTracks);
}

typedef ArtistPageKey = ({MusicSource source, String id, int offset});

final artistArtworkProvider = FutureProvider.autoDispose
    .family<String?, ({MusicSource source, String id, String name})>((
      ref,
      key,
    ) async {
      final result = await ref
          .watch(musicApiProvider)
          .searchArtists(keyword: key.name, source: key.source);
      for (final artist in result.artists) {
        if (artist.id != key.id || artist.source != key.source) continue;
        final cover = CoverImageSource.normalizeArtistUrl(artist.coverUrl);
        if (cover != null) return cover;
      }
      return null;
    });

final artistTrackPageProvider =
    FutureProvider.family<ArtistTrackPage, ArtistPageKey>((ref, key) {
      return ref
          .watch(musicApiProvider)
          .artistSongs(
            artistId: key.id,
            source: key.source,
            offset: key.offset,
            limit: onlinePlaylistDetailTrackPageSize,
          );
    });

final onlinePlaylistDetailProvider =
    FutureProvider.family<PlaylistInfo, OnlinePlaylistKey>((ref, key) {
      final api = ref.watch(musicApiProvider);
      return switch (key.kind) {
        OnlineCollectionKind.artist =>
          Future.wait([
            for (
              int offset = 0;
              offset < (key.maxTracks ?? onlinePlaylistDetailInitialTrackLimit);
              offset += onlinePlaylistDetailTrackPageSize
            )
              ref.watch(
                artistTrackPageProvider((
                  source: key.source,
                  id: key.id,
                  offset: offset,
                )).future,
              ),
          ]).then((pages) {
            final seen = <String>{};
            final tracks = [
              for (final page in pages)
                for (final track in page.tracks)
                  if (seen.add(track.id)) track,
            ];
            final first = pages.first;
            final last = pages.last;
            final total = pages.reversed
                .firstWhere(
                  (page) => page.tracks.isNotEmpty,
                  orElse: () => first,
                )
                .total;
            final exhausted =
                last.tracks.isEmpty ||
                last.offset + onlinePlaylistDetailTrackPageSize >= total;
            return PlaylistInfo(
              id: key.id,
              source: key.source,
              name: first.artistName ?? '歌手详情',
              coverUrl: first.coverUrl,
              tracks: tracks,
              trackCount: total,
              hasMoreTracks: !exhausted,
            );
          }),
        OnlineCollectionKind.playlist => api.parsePlaylist(
          input: key.id,
          source: key.source,
          maxTracks: key.maxTracks,
        ),
        OnlineCollectionKind.leaderboard => api.getLeaderboard(
          source: key.source,
          boardId: key.id,
          maxTracks: key.maxTracks,
        ),
      };
    });

class OnlineTrackCoverKey {
  const OnlineTrackCoverKey(this.music);

  final MusicInfo music;

  @override
  bool operator ==(Object other) =>
      other is OnlineTrackCoverKey &&
      other.music.source == music.source &&
      other.music.id == music.id;

  @override
  int get hashCode => Object.hash(music.source, music.id);
}

final onlineTrackCoverProvider =
    FutureProvider.family<String?, OnlineTrackCoverKey>((ref, key) {
      return ref
          .watch(musicApiProvider)
          .getPicUrl(musicInfo: key.music, preferCached: false);
    });

final leaderboardArtworkProvider =
    Provider.family<String?, LeaderboardIdentity>((ref, key) {
      final board = ref.watch(leaderboardPreviewProvider(key)).asData?.value;
      if (board == null) return null;
      if (CoverImageSource.isUsableUrl(board.coverUrl)) return board.coverUrl;
      final firstTrack = board.previewTracks.firstOrNull;
      if (firstTrack == null) return null;
      if (CoverImageSource.isUsableUrl(firstTrack.meta.picUrl)) {
        return firstTrack.meta.picUrl;
      }
      final cover = ref
          .watch(onlineTrackCoverProvider(OnlineTrackCoverKey(firstTrack)))
          .asData
          ?.value;
      return CoverImageSource.isUsableUrl(cover) ? cover : null;
    });
