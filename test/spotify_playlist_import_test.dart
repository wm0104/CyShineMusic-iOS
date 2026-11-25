import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/sdk/wy_sdk.dart';
import 'package:cy_shine_music/core/services/app_logger.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/ui/expressive_download_button.dart';
import 'package:cy_shine_music/features/downloads/download_progress.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/spotify_playlist_import.dart';
import 'package:cy_shine_music/features/search/widgets/quality_picker_sheet.dart';
import 'package:cy_shine_music/features/search/widgets/search_result_tile.dart';
import 'package:dio/dio.dart';
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
  String album = 'Match album',
}) {
  return MusicInfo.fromJson({
    'id': '${source.code}_1',
    'name': name,
    'singer': singer,
    'interval': interval,
    'source': source.code,
    'meta': {'songId': '1', 'albumName': album},
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

  test('real Wy collisions match stably with exact duration and release groups', () async {
    final fixtures = jsonDecode(
      File('test/fixtures/spotify_candidate_collisions.json').readAsStringSync(),
    ) as List;
    for (final fixture in fixtures) {
      final candidates = [
        for (final row in fixture['candidates']) MusicInfo.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
      ];
      for (final ordered in [candidates, candidates.reversed.toList()]) {
        final preview = await _importer(
          [{..._track(fixture['title'] as String, artist: 'The Weeknd'),
            'duration': fixture['spotifyDurationMs']}],
          search: (_, _) async => ordered,
        ).read(_link);
        expect(preview.tracks.single.musicInfo?.id, fixture['expectedId']);
      }
      // The source durations are real; these Spotify-side durations are test inputs.
      if (fixture['title'] == 'The Hills') {
        final ambiguous = await _importer(
          [{..._track('The Hills', artist: 'The Weeknd'), 'duration': 242290}],
          search: (_, _) async => candidates,
        ).read(_link);
        // Highlights vs Highlights (Deluxe): no Spotify album proof to choose.
        expect(ambiguous.matched, 0);
      }
    }
  });

  test('only exact duplicate releases collapse, not second-only or different albums', () async {
    final base = _candidate('Song A');
    Future<int> matches(List<MusicInfo> candidates) async => (await _importer(
      [_track('Song A')], search: (_, _) async => candidates,
    ).read(_link)).matched;
    MusicInfo copy(String id, {int? ms, String album = 'Match album'}) =>
        MusicInfo.fromJson({...base.toJson(), 'id': id, 'meta': {
          ...base.meta.raw, 'albumName': album, if (ms != null) 'durationMs': ms,
        }});
    expect(await matches([base]), 1); // Legacy interval remains supported.
    expect(await matches([base, copy('other')]), 0);
    expect(await matches([copy('a', ms: 200123), copy('b', ms: 200123)]), 1);
    expect(await matches([copy('a', ms: 200123), copy('b', ms: 200123, album: 'Other recording')]), 0);
    expect(await matches([copy('a', ms: 200122), copy('b', ms: 200124)]), 0);
    expect(await matches([copy('a', ms: 0)]), 1);
  });

  test('rejects recording tags, artist mismatch and duration outside four seconds', () async {
    final bad = [
      for (final tag in ['Live', 'Remix', 'Clean', 'Instrumental', 'Cover', 'Sped Up'])
        _candidate('Song A ($tag)'),
      _candidate('Song A', singer: 'Different singer'),
      _candidate('Song A', interval: '03:25'),
      MusicInfo.fromJson({..._candidate('Song A').toJson(), 'meta': {
        'songId': '1', 'albumName': 'Concert (Live)', 'durationMs': 200123,
      }}),
    ];
    for (final candidate in bad) {
      final preview = await _importer([_track('Song A')],
        search: (_, _) async => [candidate]).read(_link);
      expect(preview.matched, 0, reason: candidate.toJson().toString());
    }
  });

  test('a studio album title can contain a recording tag as ordinary text', () async {
    for (final album in ['Live Through This', 'A Reason to Live']) {
      final preview = await _importer(
        [_track('Violet', artist: 'Hole')],
        search: (_, _) async => [_candidate('Violet', singer: 'Hole', album: album)],
      ).read(_link);
      expect(preview.matched, 1, reason: album);
    }
  });

  test('explicit album labels reject alternate recordings of the same song', () async {
    for (final (title, artist, album) in [
      ('Radio Ga Ga', 'Queen', 'Live at Wembley'),
      ('Violet', 'Hole', 'Collection - Remix'),
      ('Violet', 'Hole', 'Concert (Live)'),
      ('Shake It Off', 'Taylor Swift', '1989 World Tour Live'),
      ('Help!', 'The Beatles', 'The Beatles Live'),
      ('稻香', '周杰伦', '夏日现场演唱会'),
    ]) {
      final preview = await _importer(
        [_track(title, artist: artist)],
        search: (_, _) async => [_candidate(title, singer: artist, album: album)],
      ).read(_link);
      expect(preview.matched, 0, reason: album);
    }
  });

  test('title-only retry handles empty combined results', () async {
    final queries = <String>[];
    final preview = await _importer([_track('Song A')], search: (query, _) async {
      queries.add(query);
      return query == 'Song A' ? [_candidate('Song A')] : [];
    }).read(_link);
    expect(queries, ['Song A Singer', 'Song A']);
    expect(preview.matched, 1);
  });

  test('title-only retry finds a match after unrelated combined results', () async {
    final queries = <(String, MusicSource)>[];
    final preview = await _importer(
      [_track('Song A')],
      search: (query, source) async {
        queries.add((query, source));
        if (query == 'Song A Singer') {
          return [
            _candidate('Song A', singer: 'Other'),
            _candidate('Song A (Live)'),
            _candidate('Song A', source: MusicSource.tx),
          ];
        }
        return [_candidate('Song A')];
      },
    ).read(_link);
    expect(preview.matched, 1);
    expect(queries, [
      ('Song A Singer', MusicSource.wy),
      ('Song A', MusicSource.wy),
    ]);
  });

  test('reimport keeps manual and same-platform matches when changing source', () async {
    const sharedUri = 'spotify:track:shared';
    const otherSourceUri = 'spotify:track:other-source';
    const sameSourceUri = 'spotify:track:same-source';
    SpotifyTrackMetadata previous(String uri, {int occurrence = 0}) =>
        SpotifyTrackMetadata(
          uri: uri,
          title: 'Previous release title',
          artist: 'Previous artist spelling',
          occurrence: occurrence,
        );
    final manual = PlaylistTrack.fromSpotify(
      previous(sharedUri),
      _candidate('Previous release title', source: MusicSource.tx),
      manual: true,
    ).copyWith(localPath: 'saved.flac');
    final invalid = PlaylistTrack.fromSpotify(
      previous(sharedUri, occurrence: 1),
      null,
    ).copyWith(musicJson: {'id': 1});
    final otherSource = PlaylistTrack.fromSpotify(
      previous(otherSourceUri),
      _candidate('Other source song', source: MusicSource.tx),
    );
    final sameSource = PlaylistTrack.fromSpotify(
      previous(sameSourceUri),
      _candidate('Same source song'),
    );
    final queried = <(String, MusicSource)>[];
    final preview = await _importer(
      [
        _track('Current title', uri: sharedUri),
        _track('Current title', uri: sharedUri),
        _track('Other source song', uri: otherSourceUri),
        _track('Same source song', uri: sameSourceUri),
      ],
      search: (query, source) async {
        queried.add((query, source));
        return [
          _candidate('Current title', source: source),
          _candidate('Other source song', source: source),
        ];
      },
    ).read(_link, existingMatches: (id) {
      expect(id, _id);
      return [manual, invalid, otherSource, sameSource];
    });

    expect(queried, [
      ('Current title Singer', MusicSource.wy),
      ('Other source song Singer', MusicSource.wy),
    ]);
    expect(preview.tracks.map((row) => row.source), [
      MusicSource.tx,
      MusicSource.wy,
      MusicSource.wy,
      MusicSource.wy,
    ]);
    expect(preview.tracks.first.spotifyMatchIsManual, isTrue);
    expect(preview.tracks.first.localPath, 'saved.flac');
    expect(preview.tracks.first.spotify?.title, 'Current title');
    expect(preview.tracks.first.spotify?.artist, 'Singer');
    expect(preview.tracks.map((row) => row.spotify?.occurrence), [0, 1, 0, 0]);
  });

  test('first import defaults to wy and explicitly selected QQ never queries wy', () async {
    final requests = <MusicSource>[];
    final importer = SpotifyPlaylistImporter(
      loadPage: (uri) async => (body: uri.path.startsWith('/embed/')
        ? _embed([_track('Song A')]) : '', redirect: null),
      enabledPlatforms: () async => [MusicSource.tx, MusicSource.wy],
      search: (_, source) async {
        requests.add(source);
        return [_candidate('Song A', source: source)];
      },
    );
    expect((await importer.read(_link)).tracks.single.source, MusicSource.wy);
    expect(requests, [MusicSource.wy]);
    requests.clear();
    expect((await importer.read(_link, source: MusicSource.tx)).tracks.single.source, MusicSource.tx);
    expect(requests, [MusicSource.tx]);
  });

  test('bounded retries retain three workers, duplicate rows and once-per-row progress', () async {
    var active = 0;
    var peak = 0;
    var requests = 0;
    final progress = <int>[];
    final preview = await _importer(
      List.generate(4, (_) => _track('Song A')),
      search: (_, _) async {
        requests++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        return [];
      },
    ).read(_link, onProgress: (done, total) => progress.add(done));
    expect(peak, 3);
    expect(requests, 8);
    expect(preview.tracks, hasLength(4));
    expect(preview.tracks.map((track) => track.identityKey).toSet(), hasLength(4));
    expect(progress, [0, 1, 2, 3, 4]);
  });

  test('selected platform failure logs safely without fallback', () async {
    final requests = <MusicSource>[];
    final progress = <int>[];
    final before = AppLogger.recentMemoryLines.length;
    final importer = SpotifyPlaylistImporter(
      loadPage: (uri) async => (
        body: uri.path.startsWith('/embed/')
            ? _embed([_track('Song A')]) : '',
        redirect: null,
      ),
      enabledPlatforms: () async => [MusicSource.tx, MusicSource.wy],
      search: (query, source) async {
        requests.add(source);
        if (source == MusicSource.tx) {
          throw Exception('https://private.example/?token=private-test-token');
        }
        return [_candidate('Song A')];
      },
    );
    await expectLater(importer.read(_link, source: MusicSource.tx,
      onProgress: (done, total) => progress.add(done)), throwsStateError);
    expect(requests, [MusicSource.tx]);
    expect(progress, [0]);
    final logs = AppLogger.recentMemoryLines.skip(before).join('\n');
    expect(logs, contains('tx search failed'));
    expect(logs, isNot(contains('private-test-token')));
    expect(logs, isNot(contains('private.example')));
  });

  test('a failed row keeps successful and unmatched rows in the preview', () async {
    final preview = await _importer(
      [_track('First'), _track('Failed'), _track('Missing'), _track('Last')],
      search: (query, _) async => switch (query) {
        'First Singer' => [_candidate('First')],
        'Failed Singer' => throw Exception('failed search'),
        'Last Singer' => [_candidate('Last')],
        _ => [],
      },
    ).read(_link);

    expect(preview.tracks.map((track) => track.name), [
      'First', 'Failed', 'Missing', 'Last',
    ]);
    expect(preview.tracks.map((track) => track.isUnmatchedSpotify), [
      false, true, true, false,
    ]);
    expect(preview.matchIssues?.failed, 1);
    expect(preview.matchIssues?.unfinished, 0);
    expect(preview.matchIssues?.rateLimited, isFalse);
  });

  test('HTTP rate limit stops new searches and retries while keeping in-flight matches', () async {
    final searches = <String>[];
    final settled = Completer<void>();
    final previewRequest = _importer(
      [_track('First'), _track('Limited'), _track('Empty'), _track('Skipped')],
      search: (query, source) async {
        searches.add(query);
        expect(source, MusicSource.wy);
        switch (query) {
          case 'First Singer':
            await settled.future;
            return [_candidate('First')];
          case 'Limited Singer':
            final options = RequestOptions();
            throw DioException.badResponse(
              statusCode: 429,
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 429),
            );
          case 'Empty Singer':
            await settled.future;
        }
        return [];
      },
    ).read(_link);
    final previewExpectation = expectLater(previewRequest, completes);
    await Future<void>.delayed(Duration.zero);
    settled.complete();
    await previewExpectation;

    final preview = await previewRequest;
    expect(searches, ['First Singer', 'Limited Singer', 'Empty Singer']);
    expect(preview.matched, 1);
    expect(preview.matchIssues?.failed, 1);
    expect(preview.matchIssues?.unfinished, 2);
    expect(preview.matchIssues?.rateLimited, isTrue);
  });

  test('Wy business-code rate limit uses the retry error when every search fails', () async {
    final searches = <String>[];
    final before = AppLogger.recentMemoryLines.length;
    final importer = _importer(
      [_track('First'), _track('Second'), _track('Third'), _track('Fourth')],
      search: (query, _) async {
        searches.add(query);
        throw const WySearchException(httpStatus: 200, responseCode: 405);
      },
    );

    await expectLater(
      importer.read(_link),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        '网易云搜索请求过于频繁，请稍后重试',
      )),
    );
    expect(searches, ['First Singer', 'Second Singer', 'Third Singer']);
    final logs = AppLogger.recentMemoryLines.skip(before).join('\n');
    expect(logs, contains('http=200 code=405'));
    expect(logs, isNot(contains('First Singer')));
  });

  test('cancellation stops retry and does not advance completed progress', () async {
    var cancelled = false;
    final progress = <int>[];
    var requests = 0;
    final preview = await _importer([_track('Song A')], search: (_, _) async {
      requests++;
      cancelled = true;
      return [];
    }).read(_link, cancelled: () => cancelled,
      onProgress: (done, total) => progress.add(done));
    expect(requests, 1);
    expect(progress, [0]);
    expect(preview.matched, 0);
  });
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
        enabledPlatforms: () async => [MusicSource.wy],
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
            return [];
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
    'ambiguous selected recordings stay unmatched without trying other sources',
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
      final preview = await importer.read(_link, source: MusicSource.tx);
      expect(visited, [MusicSource.tx]);
      expect(preview.matched, 0);
      final rematched = await importer.rematchUnmatched(
        preview.tracks, source: MusicSource.wy,
      );
      expect(visited, [MusicSource.tx, MusicSource.wy]);
      expect(rematched.single.musicInfo!.source, MusicSource.wy);
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
    'preview uses the import track row for playback and manual matching',
    (tester) async {
      tester.view.physicalSize = const Size(980, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final candidate = _candidate('SONG A', singer: 'Singer、Guest');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          spotifyPlaylistImporterProvider.overrideWithValue(
            _importer(
              [
                _track('Song A', artist: 'Singer, Guest'),
                _track('Missing'),
                _track('Failed'),
              ],
              total: 3,
              search: (query, _) async {
                if (query == 'Failed Singer') throw Exception('search failed');
                return [candidate];
              },
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
          matching: find.text('Spotify · 3 首 · Creator'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('1 首已匹配音源 · 2 首未匹配'),
        findsOneWidget,
      );
      expect(find.text('补配未匹配项'), findsOneWidget);
      expect(find.text('1 首搜索失败，可补配未匹配项'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
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
      expect(tester.widget<TrackResultRow>(missing).onSelect, isNotNull);
      expect(
        find.descendant(
          of: missing,
          matching: find.byTooltip('选择音质下载'),
        ),
        findsNothing,
      );

      final download = find.descendant(
        of: matched,
        matching: find.byKey(ValueKey('search-result-download-${candidate.id}')),
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
