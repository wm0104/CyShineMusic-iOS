import 'dart:convert';

import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/ui/expressive_download_button.dart';
import 'package:cy_shine_music/features/downloads/download_progress.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/spotify_playlist_import.dart';
import 'package:cy_shine_music/features/search/widgets/quality_picker_sheet.dart';
import 'package:cy_shine_music/features/search/widgets/search_result_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = '0123456789ABCDEFGHIJKL';
final _link = Uri.https('open.spotify.com', '/playlist/$_id');

Map<String, Object> _track(
  String title, {
  String artist = 'Singer',
  String? uri,
}) => {
  'uri': uri ?? 'spotify:track:$title',
  'title': title,
  'subtitle': artist,
  'duration': 200123,
  'entityType': 'track',
  'isExplicit': false,
};

String _embed(List<Object?> rows, {String id = _id}) {
  final entity = {
    'type': 'playlist',
    'uri': 'spotify:playlist:$id',
    'name': '我的 Spotify 歌单',
    'subtitle': 'Creator',
    'trackList': rows,
  };
  final payload = {
    'props': {
      'pageProps': {
        'state': {
          'data': {'entity': entity},
        },
      },
    },
  };
  return "<script type='application/json' id='__NEXT_DATA__'>${jsonEncode(payload)}</script>";
}

MusicInfo _candidate(
  String name, {
  String singer = 'Singer',
  String interval = '03:20',
  MusicSource source = MusicSource.wy,
}) {
  return MusicInfo.fromJson({
    'id': '${source.code}_1',
    'name': name,
    'singer': singer,
    'interval': interval,
    'source': source.code,
    'meta': {'songId': '1', 'albumName': 'Match album'},
  });
}

SpotifyPlaylistImporter _importer(
  List<Object?> rows, {
  int? total,
  SpotifyMusicSearch? search,
}) => SpotifyPlaylistImporter(
  loadPage: (uri) async => (
    body: uri.path.startsWith('/embed/')
        ? _embed(rows)
        : (total == null
              ? ''
              : '<meta content="$total" property="music:song_count">'),
    redirect: null,
  ),
  enabledPlatforms: () async => [MusicSource.wy],
  search: search ?? (_, _) async => [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'recognizes share text, locale, Spotify URI and HTTPS short links',
    () async {
      expect(spotifyShareLink('分享给你：$_link?si=token。')?.path, '/playlist/$_id');
      expect(spotifyShareLink('spotify:playlist:$_id'), _link);
      expect(spotifyShareLink('open.spotify.com/playlist/$_id'), _link);
      expect(
        spotifyShareLink('https://open.spotify.com.example/playlist/$_id'),
        isNull,
      );
      expect(
        spotifyShareLink('https://open.spotify.com@evil.example/playlist/$_id'),
        isNull,
      );
      final visited = <Uri>[];
      final importer = SpotifyPlaylistImporter(
        loadPage: (uri) async {
          visited.add(uri);
          if (uri.host == 'spotify.link') {
            return (
              body: '',
              redirect: Uri.https(
                'open.spotify.com',
                '/intl-zh/playlist/$_id',
                {'si': 'ignored'},
              ),
            );
          }
          return (
            body: uri.path.startsWith('/embed/')
                ? _embed([])
                : '<meta name="music:song_count" content="0">',
            redirect: null,
          );
        },
        enabledPlatforms: () async => [],
        search: (_, _) async => [],
      );
      final result = await importer.read(
        spotifyShareLink('来自 Spotify https://spotify.link/abc')!,
      );
      expect(result.complete, isTrue);
      expect(
        visited.map((u) => u.path),
        containsAll(['/abc', '/playlist/$_id', '/embed/playlist/$_id']),
      );
    },
  );

  test('refuses off-domain redirects before making another request', () async {
    final visited = <Uri>[];
    final importer = SpotifyPlaylistImporter(
      loadPage: (uri) async {
        visited.add(uri);
        return (
          body: '',
          redirect: Uri.parse('https://other.example/playlist/$_id'),
        );
      },
      enabledPlatforms: () async => [],
      search: (_, _) async => [],
    );
    await expectLater(
      importer.read(Uri.parse('https://spoti.fi/short')),
      throwsFormatException,
    );
    expect(visited, hasLength(1));
  });

  test(
    'matches the enabled source by title, artist and duration, keeping order and duplicate occurrences',
    () async {
      final raw = [
        _track('Song A', artist: 'Singer, Guest'),
        _track('Missing'),
        _track('Song A', artist: 'Singer, Guest'),
      ];
      final result = await _importer(
        raw,
        total: 3,
        search: (query, source) async {
          expect(source, MusicSource.wy);
          return [
            _candidate('Song A (Live)', singer: 'Singer、Guest'),
            _candidate('Song A', singer: 'Other'),
            _candidate('Song A', singer: 'Singer、Guest', interval: '03:28'),
            _candidate(
              'Song A',
              singer: 'Singer、Guest',
              source: MusicSource.tx,
            ),
            _candidate('Song A', singer: 'Singer、Guest'),
          ];
        },
      ).read(_link);
      expect(result.complete, isTrue);
      expect(result.matched, 2);
      expect(result.tracks.map((t) => t.name), ['Song A', 'Missing', 'Song A']);
      expect(result.tracks.first.singer, 'Singer, Guest');
      expect(result.tracks.first.spotify!.durationMs, 200123);
      expect(result.tracks.first.musicInfo!.source, MusicSource.wy);
      expect(result.tracks.first.musicInfo!.interval, '03:20');
      expect(result.tracks[1].sourceLabel, '未匹配音源');
      expect(result.tracks[1].toQueueEntry(playlistId: 'p'), isNull);
      expect(
        result.tracks.first.toQueueEntry(playlistId: 'p')!.musicJson!['id'],
        'wy_1',
      );
      expect(result.tracks.first.id, isNot(result.tracks.last.id));

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final store = container.read(localPlaylistsProvider.notifier);
      await store.importSpotify(result);
      final saved = await store.importSpotify(result);
      expect(container.read(localPlaylistsProvider), hasLength(1));
      expect(saved.tracks, hasLength(3));
      final reload = LocalPlaylist.tryFromJson(
        jsonDecode(prefs.getStringList(localPlaylistsStorageKey)!.single),
      )!;
      expect(
        reload.tracks.map((track) => track.toJson()),
        result.tracks.map((track) => track.toJson()),
      );
      expect(store.exportForSync().single['tracks'], hasLength(3));
    },
  );

  test(
    'never assumes embed length proves completeness and retains nonmusic entries',
    () async {
      final rows = [
        _track('Song A'),
        {..._track('Interview'), 'entityType': 'episode'},
        null,
      ];
      for (final total in [null, 8]) {
        final result = await _importer(
          rows,
          total: total,
          search: (query, source) async {
            expect(query, isNot(contains('Interview')));
            throw Exception('source unavailable');
          },
        ).read(_link);
        expect(result.complete, isFalse);
        expect(result.tracks, hasLength(3));
        expect(result.tracks.last.name, '未公开曲名（第 3 项）');
        expect(result.matched, 0);
        expect(result.total, total);
      }
    },
  );

  test(
    'tries the next enabled source when equally close recordings are ambiguous',
    () async {
      final visited = <MusicSource>[];
      final importer = SpotifyPlaylistImporter(
        loadPage: (uri) async => (
          body: uri.path.startsWith('/embed/')
              ? _embed([_track('Song A')])
              : '<meta name="music:song_count" content="1">',
          redirect: null,
        ),
        enabledPlatforms: () async => [MusicSource.tx, MusicSource.wy],
        search: (keyword, source) async {
          visited.add(source);
          final match = _candidate('Song A', source: source);
          return [
            match,
            if (source == MusicSource.tx)
              MusicInfo.fromJson({
                ...match.toJson(),
                'id': 'another-recording',
              }),
          ];
        },
      );
      final preview = await importer.read(_link);
      expect(visited, [MusicSource.tx, MusicSource.wy]);
      expect(preview.tracks.single.musicInfo!.source, MusicSource.wy);
    },
  );

  test(
    'reimport uses remote order, retains unseen rows only for partial results and keeps existing matches',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final store = container.read(localPlaylistsProvider.notifier);

      Future<LocalPlaylist> save(
        List<String> titles, {
        int? total,
        bool match = false,
      }) async {
        final preview = await _importer(
          titles.map((title) => _track(title)).toList(),
          total: total ?? titles.length,
          search: (keyword, source) async =>
              match ? [_candidate(keyword.split(' ').first)] : [],
        ).read(_link);
        return store.importSpotify(preview);
      }

      final initial = await save(['A', 'B'], match: true);
      expect(initial.tracks.last.isLocal, isFalse);
      expect(initial.tracks.last.musicInfo, isNotNull);
      final reordered = await save(['B', 'X', 'A']);
      expect(reordered.tracks.map((track) => track.name), ['B', 'X', 'A']);
      expect(
        reordered.tracks.first.toQueueEntry(playlistId: initial.id),
        isNotNull,
      );
      expect(reordered.tracks[1].isUnmatchedSpotify, isTrue);
      final partial = await save(['A', 'Y'], total: 8);
      expect(partial.tracks.map((track) => track.name), ['A', 'Y', 'B', 'X']);
      expect(partial.originTrackCount, 8);
      expect(partial.originPreviewCount, 2);
      final refreshed = await save(['X', 'B']);
      expect(refreshed.id, initial.id);
      expect(refreshed.tracks.map((track) => track.name), ['X', 'B']);
      expect(refreshed.tracks.last.musicJson, initial.tracks.last.musicJson);
      expect(
        refreshed.onlineTrackIds,
        refreshed.tracks.map((track) => track.identityKey),
      );
    },
  );

  testWidgets(
    'preview uses the import track row and only enables matched songs',
    (tester) async {
      final candidate = _candidate('SONG A', singer: 'Singer、Guest');
      final container = ProviderContainer(
        overrides: [
          spotifyPlaylistImporterProvider.overrideWithValue(
            _importer(
              [_track('Song A', artist: 'Singer, Guest'), _track('Missing')],
              total: 2,
              search: (_, _) async => [candidate],
            ),
          ),
          downloadCapabilitiesProvider.overrideWithValue(
            const AsyncData(
              DownloadCapabilities(
                sources: {
                  MusicSource.wy: [Quality.k128],
                },
                availableSources: [MusicSource.wy],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnlinePlaylistImportPage()),
        ),
      );
      await tester.enterText(find.byType(TextField), _link.toString());
      await tester.tap(find.text('解析歌单'));
      await tester.pumpAndSettle();

      final sourceLink = find.byTooltip('在 Spotify 查看歌单');
      expect(
        find.descendant(
          of: sourceLink,
          matching: find.text('Spotify · 2 首 · Creator'),
        ),
        findsOneWidget,
      );
      final matched = find.widgetWithText(TrackResultRow, 'Song A');
      final missing = find.widgetWithText(TrackResultRow, 'Missing');
      expect(tester.getSize(matched).height, tester.getSize(missing).height);
      expect(find.text('Singer, Guest · Match album'), findsOneWidget);
      expect(
        find.descendant(of: missing, matching: find.text('未匹配音源')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: missing, matching: find.text('03:20')),
        findsOneWidget,
      );
      expect(tester.widget<TrackResultRow>(matched).onPlay, isNotNull);
      expect(tester.widget<TrackResultRow>(missing).onPlay, isNull);
      expect(
        find.descendant(
          of: missing,
          matching: find.byType(ExpressiveDownloadButton),
        ),
        findsNothing,
      );

      final download = find.descendant(
        of: matched,
        matching: find.byType(ExpressiveDownloadButton),
      );
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pumpAndSettle();
      final picker = find.byType(QualityPickerSheet);
      expect(tester.widget<QualityPickerSheet>(picker).music.id, candidate.id);
      Navigator.of(tester.element(picker)).pop();
      await tester.pumpAndSettle();

      final progress = container.read(downloadProgressProvider.notifier);
      final taskId = progress.start(candidate);
      progress.updateBytes(taskId, 50, 100);
      await tester.pump();
      final button = tester.widget<ExpressiveDownloadButton>(download);
      expect(button.progress, 0.5);
      expect(button.onPressed, isNull);
      progress.finish(taskId, 'saved.flac');
      await tester.pumpAndSettle();
      expect(tester.widget<ExpressiveDownloadButton>(download).isDone, isTrue);
    },
  );

  testWidgets('partial playlist requires consent before storing visible rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(980, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        spotifyPlaylistImporterProvider.overrideWithValue(
          _importer([_track('Unmatched')], total: 120),
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
        GoRoute(path: '/playlists/:id', builder: (_, _) => const Text('已保存歌单')),
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
    await tester.enterText(find.byType(TextField), _link.toString());
    await tester.tap(find.text('解析歌单'));
    await tester.pumpAndSettle();
    expect(find.text('0 首已匹配音源 · 1 首未匹配'), findsOneWidget);
    expect(find.text('原歌单共 120 首，Spotify 预览仅提供 1 首。'), findsOneWidget);
    await tester.tap(find.text('保存到本地歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider), isEmpty);
    await tester.tap(find.text('保存到本地歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅保存这 1 首'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(
      container
          .read(localPlaylistsProvider)
          .single
          .tracks
          .single
          .isUnmatchedSpotify,
      isTrue,
    );
  });
}
