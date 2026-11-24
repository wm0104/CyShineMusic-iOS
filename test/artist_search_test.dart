import 'dart:async';
import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/artist_info.dart';
import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/online_collection_kind.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/sdk/wy_artist_sdk.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/discovery/discovery_controller.dart';
import 'package:cy_shine_music/features/discovery/online_playlist_detail_page.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/downloads/download_history_entry.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/search/search_controller.dart';
import 'package:cy_shine_music/router.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('网易云以歌手 ID 查询热度顺序、分页并保留解析和下载字段', () async {
    final result = await WyArtistSdk.search(
      keyword: 'A & B',
      page: 2,
      limit: 3,
      loadJson: (raw, {headers}) async {
        final query = Uri.parse(raw).queryParameters;
        expect(query, {
          's': 'A & B',
          'type': '100',
          'offset': '3',
          'limit': '3',
        });
        return {
          'code': 200,
          'result': {
            'artistCount': 8,
            'artists': [
              {'id': 9, 'name': 'B'},
            ],
          },
        };
      },
    );
    expect(result.artists.single.id, '9');
    expect(result.allPage, 3);
    final songs = await WyArtistSdk.songs(
      artistId: '9',
      offset: 40,
      limit: 40,
      loadJson: (raw, {headers}) async {
        expect(Uri.parse(raw).queryParameters, {
          'id': '9',
          'order': 'hot',
          'offset': '40',
          'limit': '40',
        });
        return {
          'code': 200,
          'total': 42,
          'songs': [
            for (final id in [73, 11])
              {
                'id': id,
                'name': 'Track $id',
                'duration': 74000,
                'artists': [
                  {'id': 9, 'name': 'B'},
                ],
                'album': {'id': 2, 'name': 'Album'},
                'hMusic': {'size': 9000000},
                'sqMusic': {'size': 25000000},
              },
          ],
        };
      },
    );
    expect(songs.tracks.map((s) => s.meta.songId), [73, 11]);
    expect(songs.artistName, 'B');
    expect(songs.tracks.first.singer, 'B');
    expect(
      songs.tracks.first.meta.qualitys.map((q) => q.type),
      containsAll([Quality.flac, Quality.k320]),
    );
  });

  test('歌手分页复用已读页并维持服务返回的顺序', () async {
    final api = _ArtistApi();
    final container = ProviderContainer(
      overrides: [musicApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    Future<List<String>> details(int limit) async {
      final value = await container.read(
        onlinePlaylistDetailProvider(
          OnlinePlaylistKey(
            source: MusicSource.wy,
            id: '9',
            kind: OnlineCollectionKind.artist,
            maxTracks: limit,
          ),
        ).future,
      );
      return value.tracks.map((t) => t.name).toList();
    }

    expect((await details(40)).length, 40);
    expect(await details(42), [for (int i = 0; i < 42; i++) '热歌 $i']);
    expect(api.offsets, [0, 40]);
  });

  test('未完成的歌手请求与歌曲缓存相互独立，仅用启用的歌手平台', () async {
    final api = _ArtistApi()..pendingArtistSearch = Completer<void>();
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        musicApiProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
    final settings = container.read(settingsProvider.notifier);
    for (final source in MusicApi.artistSources.where(
      (s) => s != MusicSource.wy,
    )) {
      await settings.setSearchSourceEnabled(source, false);
    }
    final controller = container.read(searchControllerProvider.notifier);
    await controller.search(keyword: 'B', source: MusicSource.all);
    controller.setCategory(SearchCategory.artists);
    expect(container.read(searchControllerProvider).source, MusicSource.wy);
    controller.setCategory(SearchCategory.songs);
    api.pendingArtistSearch!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(searchControllerProvider).source, MusicSource.all);
    expect(container.read(searchControllerProvider).response!.artists, isEmpty);
    controller.setCategory(SearchCategory.artists);
    expect(
      container.read(searchControllerProvider).response!.artists.single.id,
      '9',
    );
    await settings.setSearchSourceEnabled(MusicSource.wy, false);
    expect(container.read(searchControllerProvider).response, isNull);
    expect(api.artistSearches, 1);
  });

  testWidgets('歌手分页报错后仅重试失败页', (tester) async {
    final api = _ArtistApi()..failSecondPage = true;
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        musicApiProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: OnlinePlaylistDetailPage(
            source: MusicSource.wy,
            playlistId: '9',
            kind: OnlineCollectionKind.artist,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('重试'),
      480,
      scrollable: find.byType(Scrollable).last,
    );
    expect(api.offsets, [0, 40]);
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();
    expect(api.offsets, [0, 40, 40]);
    await tester.scrollUntilVisible(
      find.text('热歌 41'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('热歌 41'), findsOneWidget);
  });

  testWidgets('搜索结果内切换歌手，进入热门歌曲并可添加至歌单，返回保留关键词', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await SharedPreferences.getInstance();
    final handler = PlayerAudioHandler();
    late _ArtistPlayer player;
    final api = _ArtistApi();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        musicApiProvider.overrideWithValue(api),
        playerAudioHandlerProvider.overrideWithValue(handler),
        playerControllerProvider.overrideWith(
          (ref) => player = _ArtistPlayer(ref),
        ),
        downloadCapabilitiesProvider.overrideWithValue(
          const AsyncData(
            DownloadCapabilities(
              sources: {
                MusicSource.wy: [Quality.k320],
              },
              availableSources: [MusicSource.wy],
            ),
          ),
        ),
      ],
    );
    final router = createAppRouter(initialLocation: '/');
    addTearDown(() {
      router.dispose();
      container.dispose();
      unawaited(handler.disposeHandler());
    });
    final playlist = await container
        .read(localPlaylistsProvider.notifier)
        .create('收藏测试');
    await container
        .read(searchControllerProvider.notifier)
        .search(keyword: 'B', source: MusicSource.wy);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-category-artists')));
    await tester.pumpAndSettle();
    expect(api.artistSearches, 1);
    await tester.tap(find.byKey(const ValueKey('artist-wy-9')));
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.path,
      '/discover/artists/wy/9',
    );
    expect(find.text('热门歌曲  40/42'), findsOneWidget);
    final add = find.byKey(
      const ValueKey('search-result-add-to-playlist-wy_0'),
    );
    await tester.ensureVisible(add);
    await tester.tap(find.byKey(const ValueKey('search-result-download-wy_0')));
    await tester.pumpAndSettle();
    expect(find.text('选择下载音质'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏测试'));
    await tester.pumpAndSettle();
    expect(
      container
          .read(localPlaylistsProvider.notifier)
          .byId(playlist.id)!
          .tracks
          .single
          .musicId,
      'wy_0',
    );
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('artist-wy-9')), findsOneWidget);
    expect(container.read(searchControllerProvider).keyword, 'B');
    await tester.tap(find.byKey(const ValueKey('search-category-songs')));
    await tester.pumpAndSettle();
    expect(container.read(searchControllerProvider).source, MusicSource.wy);
    expect(api.songSearches, 1);
    await tester.tap(find.byKey(const ValueKey('search-category-artists')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('artist-wy-9')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('热歌 1'));
    await tester.tap(find.text('热歌 1'));
    await tester.pumpAndSettle();
    expect(player.selectedSong, 'wy_1');
    expect(player.queue, [for (var i = 0; i < 42; i++) 'wy_$i']);
    await tester.pump(const Duration(seconds: 5));
  });
}

class _ArtistPlayer extends PlayerController {
  _ArtistPlayer(super.ref);
  String? selectedSong;
  List<String?> queue = [];

  @override
  Future<void> playFromPlaylistQueue(
    DownloadHistoryEntry entry,
    List<DownloadHistoryEntry> songs,
  ) async {
    selectedSong = entry.musicId;
    queue = songs.map((e) => e.musicId).toList();
  }

  @override
  bool expandPlaylistQueue({
    required List<DownloadHistoryEntry> expectedQueue,
    required List<DownloadHistoryEntry> expandedQueue,
  }) {
    expect(expectedQueue.map((song) => song.musicId), queue);
    queue = expandedQueue.map((song) => song.musicId).toList();
    return true;
  }
}

class _ArtistApi extends MusicApi {
  Completer<void>? pendingArtistSearch;
  bool failSecondPage = false;
  int artistSearches = 0;
  int songSearches = 0;
  final offsets = <int>[];

  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async {
    songSearches++;
    return SearchResponse(
      list: const [],
      source: source,
      page: page,
      limit: limit,
      total: 0,
      allPage: 1,
    );
  }

  @override
  Future<SearchResponse> searchArtists({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async {
    artistSearches++;
    await pendingArtistSearch?.future;
    return SearchResponse(
      list: const [],
      artists: [ArtistInfo(id: '9', name: 'B', source: source)],
      source: source,
      page: page,
      limit: limit,
      total: 1,
      allPage: 1,
    );
  }

  @override
  Future<ArtistTrackPage> artistSongs({
    required String artistId,
    required MusicSource source,
    required int offset,
    required int limit,
  }) async {
    offsets.add(offset);
    if (offset == 40 && failSecondPage) {
      failSecondPage = false;
      throw Exception('临时网络错误');
    }
    return ArtistTrackPage(
      offset: offset,
      total: 42,
      artistName: 'B',
      tracks: [
        for (int i = offset; i < offset + limit && i < 42; i++)
          MusicInfo.fromJson({
            'id': 'wy_$i',
            'name': '热歌 $i',
            'singer': 'B',
            'source': 'wy',
            'meta': {
              'songId': i,
              'qualitys': [
                {'type': '320k'},
              ],
            },
          }),
      ],
    );
  }

  @override
  Future<String?> getPicUrl({
    required MusicInfo musicInfo,
    bool preferCached = true,
  }) async => null;
}
