import 'dart:async';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/artist_info.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/discovery/online_playlist_detail_page.dart';
import 'package:cy_shine_music/features/player/player_artist_resolver.dart';
import 'package:cy_shine_music/features/player/player_artists_page.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/player/player_page.dart';
import 'package:cy_shine_music/features/search/search_controller.dart';
import 'package:cy_shine_music/features/search/widgets/artist_result_tile.dart';
import 'package:cy_shine_music/router.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('only the artist row opens the real shell route; back leaves playback untouched', (tester) async {
    final h = await _pump(tester, location: '/settings');
    h.router.push('/player', extra: '/settings');
    await _frames(tester);
    final before = h.player.snapshot;
    await tester.tap(find.byKey(const ValueKey('player-header-title')));
    await _frames(tester);
    expect(h.location, '/player');
    await tester.tap(find.byKey(const ValueKey('player-open-artist')));
    await _frames(tester);
    expect(h.location, '/discover/track-artists');
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
    final h = await _pump(tester, location: '/discover/track-artists');
    final before = h.player.snapshot;
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
    expect(h.player.snapshot, same(before));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1000, 650)]) {
    for (final mode in ['loading', 'error', 'data']) {
      for (final from in ['player', 'track-artists']) {
        testWidgets('$from detail $mode back works at $size without a player loop', (tester) async {
          final h = await _pump(tester,
            location: '/discover/artists/wy/person?from=$from', size: size, mode: mode);
          final before = h.player.snapshot;
          expect(find.byTooltip('返回'), findsOneWidget);
          await tester.tap(find.byTooltip('返回'));
          await _frames(tester);
          expect(h.location, from == 'player' ? '/player' : '/discover/track-artists');
          if (from == 'player') {
            await tester.binding.handlePopRoute();
            await _frames(tester);
            expect(h.location, '/settings');
          } else {
            await tester.binding.handlePopRoute();
            await _frames(tester);
            expect(h.location, '/player');
          }
          expect(h.player.snapshot, same(before));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final source in MusicApi.artistSources) {
    testWidgets('${source.code}: confirmed credits take the real player directly to artist songs', (tester) async {
      final h = await _pump(tester, location: '/settings', identifiedSource: source);
      h.router.push('/player', extra: '/settings');
      await _frames(tester);
      final before = h.player.snapshot;
      await tester.tap(find.byKey(const ValueKey('player-open-artist')));
      await _frames(tester);
      expect(h.location, '/discover/artists/${source.code}/person?from=player');
      expect(h.api.queries, isEmpty);
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
    final h = await _pump(tester, location: '/discover/track-artists', confirmed: true);
    final row = find.byType(ArtistResultTile);
    expect(find.descendant(of: row, matching: find.byType(Hero)), findsOneWidget);
    await tester.tap(row);
    await _frames(tester);
    expect(h.location, '/discover/artists/wy/person?from=track-artists');
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(h.location, '/discover/track-artists');
    expect(find.byType(ArtistResultTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

const _state = PlayerState(track: PlayerTrack(id: 'local', kind: PlayerTrackKind.localFile,
  title: 'Song', artist: 'A、B', album: '', sourceLabel: '本地', qualityLabel: ''),
  duration: Duration(minutes: 3));

class _Player extends PlayerController {
  _Player(super.ref, this.music) { state = _state; }
  final MusicInfo? music;
  @override
  MusicInfo? get currentMusic => music;
  PlayerState get snapshot => state;
  void seed() => state = _state;
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
    return ArtistTrackPage(offset: offset, total: 0, artistName: 'A', tracks: const []);
  }
  @override
  Future<SearchResponse> searchArtists({required String keyword, required MusicSource source,
    int page = 1, int limit = 30}) async {
    queries.add(keyword);
    return SearchResponse(list: const [], artists: [ArtistInfo(id: 'person-${source.code}',
      name: keyword, source: source)], source: source, page: page, limit: limit, total: 1, allPage: 1);
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
  Size size = const Size(390, 844), String mode = 'data', bool confirmed = false,
  MusicSource? identifiedSource}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final handler = PlayerAudioHandler();
  final api = _Api(mode);
  late _Player player;
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    musicApiProvider.overrideWithValue(api),
    playerAudioHandlerProvider.overrideWithValue(handler),
    playerControllerProvider.overrideWith((ref) => player = _Player(ref,
      identifiedSource == null ? null : MusicInfo.fromJson({
        'id': 'song', 'name': 'Song', 'singer': 'A、B', 'source': identifiedSource.code,
        'meta': {'songId': 'song', 'artists': [{'id': 'person', 'name': 'A、B'}]},
      }))),
  ]);
  container.read(playerArtistSelectionProvider.notifier).state = PlayerArtistSelection(
    const PlayerArtistRequest(trackId: 'local', title: 'Song', artist: 'A、B'),
    PlayerArtistResolution(artists: confirmed
      ? [const ArtistInfo(id: 'person', name: 'A', source: MusicSource.wy)] : const [],
      unresolvedNames: confirmed ? const [] : const ['A', 'B'], source: null),
    returnLocation: '/settings');
  final router = createAppRouter(initialLocation: location);
  addTearDown(() {
    router.dispose();
    container.dispose();
    unawaited(handler.disposeHandler());
  });
  await tester.pumpWidget(UncontrolledProviderScope(container: container,
    child: MaterialApp.router(routerConfig: router)));
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
