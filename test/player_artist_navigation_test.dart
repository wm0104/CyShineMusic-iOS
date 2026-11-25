import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/artist_info.dart';
import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/discovery/online_playlist_detail_page.dart';
import 'package:cy_shine_music/features/discovery/widgets/discovery_playlist_cover.dart';
import 'package:cy_shine_music/features/downloads/download_history_entry.dart';
import 'package:cy_shine_music/features/player/player_artists_page.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/player/player_page.dart';
import 'package:cy_shine_music/features/playlists/widgets/immersive_playlist_chrome.dart';
import 'package:cy_shine_music/features/search/search_controller.dart';
import 'package:cy_shine_music/features/search/widgets/artist_result_tile.dart';
import 'package:cy_shine_music/features/shell/shell_navigation.dart';
import 'package:cy_shine_music/features/shell/widgets/toolbar_action.dart';
import 'package:cy_shine_music/features/songs/songs_page.dart';
import 'package:cy_shine_music/router.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS edge swipes return from one artist and close the player to its origin', (tester) async {
    const origin = '/settings?origin=gesture-test';
    final h = await _pump(
      tester,
      location: origin,
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
    );
    await _tapToolbar(tester, '播放页');
    final before = h.player.snapshot;
    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/person');
    _expectSelectedTab(tester, '播放页');

    await _swipeBack(tester);
    expect(h.location, '/player');
    expect(tester.widget<PlayerPage>(find.byType(PlayerPage)).active, isTrue);

    await _swipeBack(tester);
    expect(h.location, origin);
    await _swipeBack(tester);
    expect(h.location, origin);
    await _tapToolbar(tester, '发现');
    expect(h.location, '/');
    expect(h.player.snapshot, same(before));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS edge swipes step through artist detail, artist list and player', (tester) async {
    final h = await _pump(
      tester,
      location: '/settings',
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
      artists: _multipleCredits,
    );
    await _tapToolbar(tester, '播放页');
    final before = h.player.snapshot;
    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    expect(h.location, '/player/track-artists');
    _expectSelectedTab(tester, '播放页');

    await tester.tap(find.byKey(const ValueKey('artist-wy-first')));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/first');
    _expectSelectedTab(tester, '播放页');

    await _swipeBack(tester);
    expect(h.location, '/player/track-artists');
    await _swipeBack(tester);
    expect(h.location, '/player');
    expect(h.player.snapshot, same(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS swipe back from song artists leaves Discover reachable', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      location: '/songs',
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
      artists: _multipleCredits,
    );
    final before = h.player.snapshot;
    await _tapToolbar(tester, '播放页');
    expect(h.location, '/player');

    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    expect(h.location, '/player/track-artists');

    await tester.tap(find.byKey(const ValueKey('artist-wy-first')));
    await _frames(tester);
    const detail = '/player/artists/wy/first';
    expect(h.location, detail);
    _expectSelectedTab(tester, '播放页');

    await _swipeBack(tester);
    expect(h.location, '/player/track-artists');
    await _swipeBack(tester);
    expect(h.location, '/player');
    await _edgeDrag(tester);
    await tester.pump();
    expect(h.location, '/songs');
    await _edgeDrag(tester);
    await _frames(tester);
    expect(h.location, '/songs');
    expect(find.byType(SongsPage), findsOneWidget);
    _expectSelectedTab(tester, '歌曲');
    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.active, isFalse);
    expect(player.progress.value, 0);
    for (var swipe = 0; swipe < 3; swipe++) {
      await _swipeBack(tester);
      expect(h.location, '/songs');
    }
    await _tapToolbar(tester, '发现');

    expect(h.location, '/');
    expect(find.byType(PlayerArtistsPage), findsNothing);
    expect(h.player.snapshot, same(before));
  });

  testWidgets('repeated iOS swipes from player artist pages reach Discover', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      location: '/',
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
      artists: _multipleCredits,
    );
    final before = h.player.snapshot;
    const detail = '/player/artists/wy/first';

    for (var visit = 0; visit < 2; visit++) {
      await _tapToolbar(tester, '播放页');
      await tester.tap(find.byKey(const ValueKey('player-open-artist')));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('artist-wy-first')));
      await _frames(tester);
      expect(h.location, detail);

      await _tapToolbar(tester, '播放页');
      expect(h.location, '/player');
      expect(find.byType(PlayerArtistsPage), findsNothing);

      await _swipeBack(tester);
      expect(h.location, '/');
      await _swipeBack(tester);
      expect(h.location, '/');
    }
    expect(h.player.snapshot, same(before));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing a song from a playback artist reuses the original player', (tester) async {
    final h = await _pump(
      tester,
      location: '/songs',
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
      mode: 'tracks',
    );
    await _openPlayerArtists(tester);
    expect(h.location, '/player/artists/wy/person');
    final song = find.text('歌手详情测试歌曲');
    await tester.ensureVisible(song);
    await tester.tap(song);
    await _frames(tester);

    expect(h.location, '/player');
    expect(h.player.playedSongs, ['wy_42']);
    await _swipeBack(tester);
    expect(h.location, '/songs');
    _expectSelectedTab(tester, '歌曲');
    await _swipeBack(tester);
    expect(h.location, '/songs');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a library tab is reachable directly from a playback artist', (tester) async {
    final h = await _pump(
      tester,
      location: '/settings',
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
    );
    await _openPlayerArtists(tester);
    expect(h.location, '/player/artists/wy/person');
    _expectSelectedTab(tester, '播放页');
    await _tapToolbar(tester, '歌曲');
    expect(h.location, '/songs');
    _expectSelectedTab(tester, '歌曲');
    await _swipeBack(tester);
    expect(h.location, '/songs');
    await _tapToolbar(tester, '发现');
    expect(h.location, '/');
    _expectSelectedTab(tester, '发现');
    expect(find.byType(OnlinePlaylistDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('artists show the Playback tab after opening from the mini capsule', (tester) async {
    final h = await _pump(
      tester,
      location: '/songs',
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
    );
    await tester.drag(_toolbar('播放页'), const Offset(-200, 0));
    await _frames(tester);
    expect(_toolbar('播放页'), findsNothing);
    final miniPlayer = find.byTooltip('打开播放页').hitTestable();
    expect(miniPlayer, findsOneWidget);
    await tester.tap(miniPlayer);
    await _frames(tester);
    expect(h.location, '/player');
    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/person');
    _expectSelectedTab(tester, '播放页');
    await _swipeBack(tester);
    expect(h.location, '/player');
    await _swipeBack(tester);
    expect(h.location, '/songs');
    _expectSelectedTab(tester, '歌曲');
    expect(tester.takeException(), isNull);
  });

  for (final openPlayer in [false, true]) {
    final action = openPlayer ? 'opens the player before closing' : 'swipes back';
    testWidgets('standalone artist list $action and reaches Songs', (tester) async {
      final h = await _pump(
        tester,
        location: '/player/track-artists',
        platform: TargetPlatform.iOS,
      );
      expect(find.byType(PlayerArtistsPage), findsOneWidget);
      if (openPlayer) {
        await _tapToolbar(tester, '播放页');
        expect(h.location, '/player');
      }
      await _swipeBack(tester);
      expect(h.location, '/songs');
      expect(find.byType(PlayerArtistsPage), findsNothing);
      await _swipeBack(tester);
      expect(h.location, '/songs');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an external player entry restores the existing player and origin', (
    tester,
  ) async {
    const origin = '/songs?origin=external-player';
    final h = await _pump(
      tester,
      location: origin,
      identifiedSource: MusicSource.wy,
      platform: TargetPlatform.iOS,
      artists: [
        {'id': 'first', 'name': 'A'},
        {'id': 'second', 'name': 'B'},
      ],
    );
    await tester.tap(find.byTooltip('播放页'));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('artist-wy-first')));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/first');

    openPlayerRoute(h.router);
    await _frames(tester);
    expect(h.location, '/player');
    await _swipeBack(tester);
    expect(h.location, origin);
    expect(find.byType(PlayerArtistsPage), findsNothing);
  });

  testWidgets('iOS edge swipe respects root tabs, modals and drag direction', (tester) async {
    final h = await _pump(
      tester,
      location: '/settings/sources',
      platform: TargetPlatform.iOS,
    );
    const edge = Offset(4, 360);
    for (final drag in [
      (edge, const Offset(36, 0)),
      (edge, const Offset(-120, 0)),
      (edge, const Offset(40, 160)),
      (const Offset(60, 360), const Offset(180, 0)),
    ]) {
      await tester.dragFrom(drag.$1, drag.$2);
      await _frames(tester);
      expect(h.location, '/settings/sources');
    }

    final cancelled = await tester.startGesture(edge);
    await cancelled.moveBy(const Offset(180, 0));
    await cancelled.cancel();
    await _frames(tester);
    expect(h.location, '/settings/sources');

    final context = h.router.routerDelegate.navigatorKey.currentContext!;
    unawaited(showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('测试弹层'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭测试弹层'),
          ),
        ],
      ),
    ));
    await _frames(tester);
    await _swipeBack(tester);
    expect(find.text('测试弹层'), findsOneWidget);
    expect(h.location, '/settings/sources');
    await tester.tap(find.text('关闭测试弹层'));
    await _frames(tester);

    await _swipeBack(tester);
    expect(h.location, '/settings');
    await _swipeBack(tester);
    expect(h.location, '/settings');
    expect(find.text('再次点击返回键切换到桌面'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the artist row opens the real shell route; back leaves playback untouched', (tester) async {
    final h = await _pump(tester, location: '/settings');
    await _tapToolbar(tester, '播放页');
    final before = h.player.snapshot;
    await tester.tap(find.byKey(const ValueKey('player-header-title')));
    await _frames(tester);
    expect(h.location, '/player');
    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    expect(h.location, '/player/track-artists');
    expect(find.byType(PlayerArtistsPage), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(h.api.queries, isEmpty);
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(h.location, '/player');
    expect(tester.widget<PlayerPage>(find.byType(PlayerPage)).active, isTrue);
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(h.location, '/settings');
    expect(h.player.snapshot, same(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unresolved individual uses artist search and permits a different platform identity', (tester) async {
    final h = await _pump(
      tester,
      location: '/songs',
      platform: TargetPlatform.iOS,
    );
    final before = h.player.snapshot;
    await _openPlayerArtists(tester);
    expect(h.location, '/player/track-artists');
    await tester.tap(find.byKey(const ValueKey('player-artist-search-B')));
    await _frames(tester);
    expect(h.location, '/');
    expect(h.container.read(searchControllerProvider).category, SearchCategory.artists);
    expect(h.container.read(searchControllerProvider).keyword, 'B');
    expect(h.api.queries, isNot(contains('A、B')));
    h.container.read(searchControllerProvider.notifier).setSource(MusicSource.tx);
    await _frames(tester);
    expect(h.container.read(searchControllerProvider).source, MusicSource.tx);
    await tester.tap(find.byKey(const ValueKey('artist-tx-person-tx')));
    await _frames(tester);
    expect(h.location, '/discover/artists/tx/person-tx');
    expect(tester.widget<OnlinePlaylistDetailPage>(find.byType(OnlinePlaylistDetailPage)).source,
      MusicSource.tx);
    await _tapToolbar(tester, '歌曲');
    expect(h.location, '/songs');
    await _tapToolbar(tester, '发现');
    expect(h.location, '/discover/artists/tx/person-tx');
    await _swipeBack(tester);
    expect(h.location, '/');
    expect(h.container.read(searchControllerProvider).keyword, 'B');
    expect(h.container.read(searchControllerProvider).source, MusicSource.tx);
    expect(h.player.snapshot, same(before));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1000, 650)]) {
    for (final mode in ['loading', 'error', 'data']) {
      for (final fromList in [false, true]) {
        final entry = fromList ? 'artist list' : 'player';
        testWidgets('$entry detail $mode back works at $size without a player loop', (tester) async {
          final h = await _pump(tester,
            location: '/settings', size: size, mode: mode,
            identifiedSource: MusicSource.wy,
            artists: fromList ? _multipleCredits : null);
          final before = h.player.snapshot;
          await _openPlayerArtists(tester);
          if (fromList) {
            expect(h.location, '/player/track-artists');
            await tester.tap(find.byKey(const ValueKey('artist-wy-first')));
            await _frames(tester);
          }
          expect(h.location, fromList ? '/player/artists/wy/first' : '/player/artists/wy/person');
          expect(find.byTooltip('返回'), findsOneWidget);
          await tester.tap(find.byTooltip('返回'));
          await _frames(tester);
          expect(h.location, fromList ? '/player/track-artists' : '/player');
          if (fromList) {
            await tester.binding.handlePopRoute();
            await _frames(tester);
            expect(h.location, '/player');
          }
          await tester.binding.handlePopRoute();
          await _frames(tester);
          expect(h.location, '/settings');
          expect(h.player.snapshot, same(before));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final source in MusicApi.artistSources) {
    testWidgets('${source.code}: confirmed credits take the real player directly to artist songs', (tester) async {
      final h = await _pump(tester, location: '/settings', identifiedSource: source);
      final before = h.player.snapshot;
      await _openPlayerArtists(tester);
      expect(h.location, '/player/artists/${source.code}/person');
      expect(h.api.queries, ['A、B']);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.location, '/player');
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.location, '/settings');
      expect(h.player.snapshot, same(before));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('confirmed artist row retains Hero and container-transform payload and returns to the list', (tester) async {
    final h = await _pump(tester, location: '/settings',
      identifiedSource: MusicSource.wy, artists: _multipleCredits);
    await _openPlayerArtists(tester);
    final row = find.byKey(const ValueKey('artist-wy-first'));
    expect(find.descendant(of: row, matching: find.byType(Hero)), findsOneWidget);
    await tester.tap(row);
    await _frames(tester);
    expect(h.location, '/player/artists/wy/first');
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(h.location, '/player/track-artists');
    expect(find.byType(ArtistResultTile), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback credits use the real artist artwork in the list and detail', (tester) async {
    final h = await _pump(tester, location: '/settings', identifiedSource: MusicSource.wy,
      artists: [
        {'id': '12200029', 'name': 'A', 'img1v1Url': _wyPlaceholder},
        {'id': '1132392', 'name': 'B', 'img1v1Url': _wyPlaceholder},
      ]);
    final before = h.player.snapshot;
    await _openPlayerArtists(tester);
    expect(h.location, '/player/track-artists');
    expect(h.api.queries, unorderedEquals(['A', 'B']));
    for (final entry in _artwork.entries) {
      final tile = find.byKey(ValueKey('artist-wy-${entry.key}'));
      final cover = tester.widget<DiscoveryPlaylistCover>(find.descendant(
        of: tile, matching: find.byType(DiscoveryPlaylistCover)));
      expect(cover.url, entry.value);
    }
    await tester.tap(find.byKey(const ValueKey('artist-wy-1132392')));
    await _frames(tester);
    expect(h.location, '/player/artists/wy/1132392');
    final detailArtwork = tester.widget<PlaylistArtworkTheme>(find.byType(PlaylistArtworkTheme))
      .artworkProvider as CachedNetworkImageProvider;
    expect(detailArtwork.url, startsWith(_artwork['1132392']!));
    expect(h.api.queries, unorderedEquals(['A', 'B']));
    expect(h.player.snapshot, same(before));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct playback route uses the same real artist artwork', (tester) async {
    final h = await _pump(tester, location: '/settings', identifiedSource: MusicSource.wy,
      artists: [{'id': '1132392', 'name': 'A、B', 'img1v1Url': _wyPlaceholder}]);
    await _openPlayerArtists(tester);
    expect(h.location, '/player/artists/wy/1132392');
    expect(h.api.queries, ['A、B']);
    final detailArtwork = tester.widget<PlaylistArtworkTheme>(find.byType(PlaylistArtworkTheme))
      .artworkProvider as CachedNetworkImageProvider;
    expect(detailArtwork.url, startsWith(_artwork['1132392']!));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}

const _wyPlaceholder = 'https://p1.music.126.net/6y-UleORITEDbvrOLV0Q8A==/5639395138885805.jpg';
const _multipleCredits = [
  {'id': 'first', 'name': 'A'},
  {'id': 'second', 'name': 'B'},
];
const _artwork = {
  '12200029': 'https://example.com/12200029.jpg',
  '1132392': 'https://example.com/1132392.jpg',
};

const _state = PlayerState(track: PlayerTrack(id: 'local', kind: PlayerTrackKind.localFile,
  title: 'Song', artist: 'A、B', album: '', sourceLabel: '本地', qualityLabel: ''),
  duration: Duration(minutes: 3));

class _Player extends PlayerController {
  _Player(super.ref, this.music) { state = _state; }
  final MusicInfo? music;
  final playedSongs = <String?>[];
  @override
  MusicInfo? get currentMusic => music;
  PlayerState get snapshot => state;
  void seed() => state = _state;

  @override
  Future<void> playFromPlaylistQueue(
    DownloadHistoryEntry entry,
    List<DownloadHistoryEntry> songs,
  ) async {
    playedSongs.add(entry.musicId);
  }
}

class _Api extends MusicApi {
  _Api(this.mode);
  final String mode;
  final pending = Completer<ArtistTrackPage>();
  final queries = <String>[];
  @override
  Future<ArtistTrackPage> artistSongs({required String artistId,
    required MusicSource source, required int offset, required int limit}) async {
    if (mode == 'loading') return pending.future;
    if (mode == 'error') throw StateError('offline');
    if (mode == 'tracks') {
      return ArtistTrackPage(
        offset: offset, total: 1, artistName: 'A',
        tracks: [
          MusicInfo.fromJson({
            'id': 'wy_42', 'name': '歌手详情测试歌曲', 'singer': 'A',
            'source': 'wy', 'meta': {'songId': '42'},
          }),
        ],
      );
    }
    return ArtistTrackPage(offset: offset, total: 0, artistName: 'A', tracks: const [],
      coverUrl: _artwork.containsKey(artistId) ? _wyPlaceholder : null);
  }
  @override
  Future<SearchResponse> searchArtists({required String keyword, required MusicSource source,
    int page = 1, int limit = 30}) async {
    queries.add(keyword);
    final artistId = switch (keyword) {
      'A' => '12200029',
      'B' || 'A、B' => '1132392',
      _ => null,
    };
    final artists = [
      ArtistInfo(id: 'person-${source.code}', name: keyword, source: source,
        coverUrl: source == MusicSource.wy ? 'https://example.com/homonym.jpg' : null),
      if (source == MusicSource.wy && artistId != null) ...[
        ArtistInfo(id: artistId, name: keyword, source: MusicSource.tx,
          coverUrl: 'https://example.com/foreign.jpg'),
        ArtistInfo(id: artistId, name: keyword, source: source,
          coverUrl: _artwork[artistId]),
      ],
    ];
    return SearchResponse(list: const [], artists: artists, source: source,
      page: page, limit: limit, total: artists.length, allPage: 1);
  }
}

class _Harness {
  _Harness(this.router, this.container, this.player, this.api);
  final GoRouter router;
  final ProviderContainer container;
  final _Player player;
  final _Api api;
  String get location => router.routeInformationProvider.value.uri.toString();
}

Future<_Harness> _pump(WidgetTester tester, {required String location,
  Size size = const Size(390, 844), String mode = 'data',
  MusicSource? identifiedSource, List<Map<String, String>>? artists,
  TargetPlatform? platform}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({
    'navigation_mode': AppNavigationMode.singleCapsule.code,
  });
  final prefs = await SharedPreferences.getInstance();
  final handler = PlayerAudioHandler();
  final api = _Api(mode);
  late _Player player;
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    musicApiProvider.overrideWithValue(api),
    playerAudioHandlerProvider.overrideWithValue(handler),
    downloadCapabilitiesProvider.overrideWithValue(
      const AsyncData(DownloadCapabilities(
        sources: {MusicSource.wy: [Quality.k320]},
        availableSources: [MusicSource.wy],
      )),
    ),
    playerControllerProvider.overrideWith((ref) => player = _Player(ref,
      identifiedSource == null ? null : MusicInfo.fromJson({
        'id': 'song', 'name': 'Song', 'singer': 'A、B', 'source': identifiedSource.code,
        'meta': {'songId': 'song', 'artists': artists ?? [{'id': 'person', 'name': 'A、B'}]},
      }))),
  ]);
  final router = createAppRouter(initialLocation: location);
  addTearDown(() {
    router.dispose();
    container.dispose();
    unawaited(handler.disposeHandler());
  });
  await tester.pumpWidget(UncontrolledProviderScope(container: container,
    child: MaterialApp.router(
      routerConfig: router,
      theme: ThemeData(platform: platform),
    )));
  await _frames(tester);
  player.seed();
  await _frames(tester);
  return _Harness(router, container, player, api);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _swipeBack(WidgetTester tester) async {
  await _edgeDrag(tester);
  await _frames(tester);
}

Future<void> _edgeDrag(WidgetTester tester) async {
  await tester.dragFrom(const Offset(4, 360), const Offset(290, 0));
}

Finder _toolbar(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is ToolbarAction && widget.tooltip == tooltip,
).hitTestable();

Future<void> _tapToolbar(WidgetTester tester, String tooltip) async {
  await tester.tap(_toolbar(tooltip));
  await _frames(tester);
}

void _expectSelectedTab(WidgetTester tester, String tooltip) {
  for (final tab in ['发现', '歌曲', '播放页', '设置']) {
    expect(tester.widget<ToolbarAction>(_toolbar(tab)).selected, tab == tooltip);
  }
}

Future<void> _openPlayerArtists(WidgetTester tester) async {
  await _tapToolbar(tester, '播放页');
  await tester.tap(find.byKey(const ValueKey('player-open-artist')));
  await _frames(tester);
}
