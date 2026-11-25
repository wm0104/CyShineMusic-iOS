import 'dart:convert';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/ui/expressive_download_button.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/spotify_playlist_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _playlistId = '0123456789ABCDEFGHIJKL';

MusicInfo _candidate(String id, String title) => MusicInfo.fromJson({
  'id': id,
  'name': title,
  'singer': 'Singer',
  'interval': '03:00',
  'source': 'wy',
  'meta': {'songId': id, 'albumName': id},
});

class _PickerApi extends MusicApi {
  String version = '';

  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async => SearchResponse(
    list: [_candidate('chosen-$keyword$version', '选择 $keyword')],
    page: page,
    limit: limit,
    allPage: 1,
    total: 1,
    source: source,
  );
}

void main() {
  testWidgets(
    'manual choices survive duplicate rows, rematch, refetch and save',
    (tester) async {
      tester.view.physicalSize = const Size(980, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final automaticQueries = <String>[];
      final pickerApi = _PickerApi();
      final entity = {
        'type': 'playlist',
        'uri': 'spotify:playlist:$_playlistId',
        'name': '测试歌单',
        'trackList': [
          for (final title in ['Same', 'Same', 'Missing', 'Other'])
            {
              'uri': 'spotify:track:$title',
              'title': title,
              'subtitle': 'Singer',
              'duration': 180000,
              'entityType': 'track',
            },
        ],
      };
      final payload = jsonEncode({
        'props': {
          'pageProps': {
            'state': {
              'data': {'entity': entity},
            },
          },
        },
      });
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          musicApiProvider.overrideWithValue(pickerApi),
          spotifyPlaylistImporterProvider.overrideWithValue(
            SpotifyPlaylistImporter(
              loadPage: (uri) async => (
                body: uri.path.startsWith('/embed/')
                    ? '<script id="__NEXT_DATA__">$payload</script>'
                    : '<meta property="music:song_count" content="4">',
                redirect: null,
              ),
              enabledPlatforms: () async => [MusicSource.wy],
              search: (query, _) async {
                automaticQueries.add(query);
                return query.startsWith('Same')
                    ? [_candidate('auto', 'Same')]
                    : [];
              },
            ),
          ),
        ],
      );
      final router = GoRouter(
        initialLocation: '/playlists/import',
        routes: [
          GoRoute(
            path: '/playlists/import',
            builder: (_, _) => const OnlinePlaylistImportPage(),
          ),
          GoRoute(path: '/playlists/:id', builder: (_, _) => const Text('已保存')),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.enterText(
        find.byType(TextField),
        'https://open.spotify.com/playlist/$_playlistId',
      );
      await tester.tap(find.text('解析歌单'));
      await tester.pumpAndSettle();
      expect(find.text('2 首已匹配音源 · 2 首未匹配'), findsOneWidget);

      Future<void> choose(
        String title,
        int occurrence, {
        bool unmatched = false,
      }) async {
        final button = find.byKey(
          ValueKey('spotify-match-spotify:spotify:track:$title:$occurrence'),
        );
        expect(
          tester.widget<ExpressiveDownloadButton>(button).tooltip,
          unmatched ? '手动匹配' : '更换匹配',
        );
        await tester.tap(unmatched ? find.text(title) : button);
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择 $title Singer'));
        await tester.pumpAndSettle();
      }

      await choose('Same', 1);
      await choose('Missing', 0, unmatched: true);
      expect(find.text('3 首已匹配音源 · 1 首未匹配'), findsOneWidget);
      expect(container.read(localPlaylistsProvider), isEmpty);
      for (final action in ['补配未匹配项', '解析歌单']) {
        automaticQueries.clear();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        expect(automaticQueries, ['Other Singer', 'Other']);
        expect(find.text('Singer · chosen-Same Singer'), findsOneWidget);
        expect(find.text('Singer · chosen-Missing Singer'), findsOneWidget);
      }
      await tester.tap(find.text('保存到本地歌单'));
      await tester.pumpAndSettle();
      final stored = container.read(localPlaylistsProvider).single.tracks;
      expect(stored.map((track) => track.musicId), [
        'auto',
        'chosen-Same Singer',
        'chosen-Missing Singer',
        'spotify:track:Other',
      ]);
      expect(stored.map((track) => track.spotifyMatchIsManual), [
        false,
        true,
        true,
        false,
      ]);
      expect(stored.map((track) => track.name), [
        'Same',
        'Same',
        'Missing',
        'Other',
      ]);
      expect(stored.map((track) => track.spotify!.occurrence), [0, 1, 0, 0]);

      // Refresh the same playlist while another page edits the second occurrence.
      router.go('/playlists/import');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://open.spotify.com/playlist/$_playlistId',
      );
      await tester.tap(find.text('解析歌单'));
      await tester.pumpAndSettle();
      pickerApi.version = '-draft';
      await choose('Same', 0);
      await choose('Same', 1);
      await choose('Missing', 0);
      final saved = container.read(localPlaylistsProvider).single;
      final store = container.read(localPlaylistsProvider.notifier);
      await store.setSpotifyTrackMatch(
        saved.id,
        expected: saved.tracks.first,
        music: _candidate('first-saved', 'Same'),
      );
      await container
          .read(localPlaylistsProvider.notifier)
          .setSpotifyTrackMatch(
            saved.id,
            expected: saved.tracks[1],
            music: _candidate('newer-saved', 'Same'),
          );
      await tester.tap(find.text('解析歌单'));
      await tester.pumpAndSettle();
      expect(find.text('Singer · newer-saved'), findsOneWidget);
      expect(find.text('Singer · first-saved'), findsOneWidget);
      expect(find.text('Singer · chosen-Missing Singer-draft'), findsOneWidget);
      // Saving another row must not claim an edit to this refreshed row.
      await store.setSpotifyTrackMatch(
        saved.id,
        expected: container.read(localPlaylistsProvider).single.tracks.first,
        music: _candidate('first-latest', 'Same'),
      );
      pickerApi.version = '-latest';
      await choose('Same', 1);
      await tester.tap(find.text('保存到本地歌单'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(localPlaylistsProvider)
            .single
            .tracks
            .map((track) => track.musicId),
        [
          'first-latest',
          'chosen-Same Singer-latest',
          'chosen-Missing Singer-draft',
          'spotify:track:Other',
        ],
      );
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    },
  );
}
