import 'dart:async';

import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/spotify_playlist_import.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlaylistTrack row(int occurrence, {bool matched = false, String title = 'A'}) {
  final original = SpotifyTrackMetadata(uri: 'spotify:track:$title', title: title,
    artist: 'Singer', occurrence: occurrence, durationMs: 200000);
  return PlaylistTrack.fromSpotify(original, matched ? candidate(MusicSource.wy) : null);
}
MusicInfo candidate(MusicSource source, {String title = 'A'}) => MusicInfo.fromJson({
  'id': '${source.code}-$title', 'name': title, 'singer': 'Singer',
  'meta': {'songId': title, 'albumName': 'Album'},
  'source': source.code, 'interval': '03:20',
});
SpotifyPlaylistPreview preview(List<PlaylistTrack> tracks) => SpotifyPlaylistPreview(
  id: 'test-playlist', name: 'Saved', tracks: tracks, total: tracks.length,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('default is wy regardless of enabled order; explicit QQ only searches QQ', () async {
    final visited = <MusicSource>[];
    final importer = SpotifyPlaylistImporter(
      enabledPlatforms: () async => [MusicSource.tx, MusicSource.wy],
      search: (_, source) async { visited.add(source); return [candidate(source)]; },
    );
    final first = await importer.rematchUnmatched([row(0)]);
    expect(visited, [MusicSource.wy]);
    expect(first.single.source, MusicSource.wy);
    final second = await importer.rematchUnmatched(first, source: MusicSource.tx);
    expect(identical(second.single, first.single), isTrue);
    expect(visited, [MusicSource.wy]);
    await importer.rematchUnmatched([row(0)], source: MusicSource.tx);
    expect(visited, [MusicSource.wy, MusicSource.tx]);
  });

  test('disabled selection reports fact and never searches another enabled platform', () async {
    var searches = 0;
    final importer = SpotifyPlaylistImporter(
      enabledPlatforms: () async => [MusicSource.tx],
      search: (_, _) async { searches++; return []; },
    );
    await expectLater(importer.rematchUnmatched([row(0)]), throwsStateError);
    expect(searches, 0);
  });

  test('preview rematch preserves matched short resources, duplicates, downloads and order', () async {
    final matched = row(0, matched: true).copyWith(localPath: '/download/a');
    final originals = [matched, row(1), row(2)];
    final importer = SpotifyPlaylistImporter(
      enabledPlatforms: () async => [MusicSource.tx],
      search: (_, source) async => [candidate(source)],
    );
    final result = await importer.rematchUnmatched(originals, source: MusicSource.tx);
    expect(identical(result.first, matched), isTrue);
    expect(result.map((e) => e.identityKey), originals.map((e) => e.identityKey));
    expect(result.skip(1).map((e) => e.source), everyElement(MusicSource.tx));
    expect(result.first.localPath, '/download/a');
  });

  test('cancelled rematch returns original snapshot, never a half-matched result', () async {
    var cancelled = false;
    final original = [row(0), row(1)];
    final importer = SpotifyPlaylistImporter(
      enabledPlatforms: () async => [MusicSource.tx],
      search: (_, source) async { cancelled = true; return [candidate(source)]; },
    );
    final result = await importer.rematchUnmatched(original, source: MusicSource.tx,
      cancelled: () => cancelled);
    expect(result, original);
  });

  test('saved patch preserves current custom order, successful matches and attachments', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    final store = container.read(localPlaylistsProvider.notifier);
    final original = [row(0, matched: true).copyWith(localPath: '/download/a'), row(1), row(2)];
    final saved = await store.importSpotify(preview(original));
    final order = original.reversed.map((e) => e.identityKey).toList();
    await store.setCustomTrackOrder(saved.id, order);
    final replacements = [original.first, PlaylistTrack.fromSpotify(row(1).spotify!, candidate(MusicSource.tx)),
      PlaylistTrack.fromSpotify(row(2).spotify!, candidate(MusicSource.tx))];
    expect(await store.patchSpotifyMatches(saved.id, snapshot: original, replacements: replacements), 2);
    final current = container.read(localPlaylistsProvider).single;
    expect(current.customTrackOrder, order);
    expect(current.tracks.first.toJson(), original.first.toJson());
    expect(current.tracks.map((e) => e.identityKey), original.map((e) => e.identityKey));
    expect(await store.patchSpotifyMatches(saved.id, snapshot: original, replacements: replacements), 0);
    final reloaded = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(reloaded.dispose);
    expect(reloaded.read(localPlaylistsProvider).single.toJson(), current.toJson());
  });

  testWidgets('saved wy matches A then QQ matches B and one save preserves both without touching player', (tester) async {
    tester.view.physicalSize = const Size(980, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final visited = <MusicSource>[];
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerControllerProvider.overrideWith((ref) => throw StateError('Must not access player or queue')),
      spotifyPlaylistImporterProvider.overrideWithValue(SpotifyPlaylistImporter(
        loadPage: (_) => throw StateError('Saved rematch must not fetch remote playlist'),
        enabledPlatforms: () async => [MusicSource.wy, MusicSource.tx],
        search: (keyword, source) async {
          visited.add(source);
          final title = keyword.split(' ').first;
          if ((source == MusicSource.wy && title == 'A') ||
              (source == MusicSource.tx && title == 'B')) return [candidate(source, title: title)];
          return [];
        },
      )),
    ]);
    addTearDown(container.dispose);
    final store = container.read(localPlaylistsProvider.notifier);
    final originals = [row(0, matched: true), row(1), row(0, title: 'B')];
    final saved = await store.importSpotify(preview(originals));
    await store.setCustomTrackOrder(saved.id, originals.reversed.map((e) => e.identityKey).toList());
    final router = GoRouter(initialLocation: '/home', routes: [
      GoRoute(path: '/home', builder: (_, _) => const Text('Home')),
      GoRoute(path: '/playlists/import', builder: (_, _) => const OnlinePlaylistImportPage()),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp.router(routerConfig: router)));
    router.push('/playlists/import?rematch=${saved.id}');
    await tester.pumpAndSettle();
    await tester.tap(find.text('补配未匹配项'));
    await tester.pumpAndSettle();
    expect(visited, everyElement(MusicSource.wy));
    expect(container.read(localPlaylistsProvider).single.tracks[1].isUnmatchedSpotify, isTrue);
    visited.clear();
    await tester.tap(find.text('QQ'));
    await tester.tap(find.text('补配未匹配项'));
    await tester.pumpAndSettle();
    expect(visited, [MusicSource.tx]);
    expect(container.read(localPlaylistsProvider).single.tracks.last.isUnmatchedSpotify, isTrue);
    await tester.ensureVisible(find.text('保存到本地歌单'));
    await tester.tap(find.text('保存到本地歌单'));
    await tester.pumpAndSettle();
    final current = container.read(localPlaylistsProvider).single;
    expect(current.tracks.first.toJson(), originals.first.toJson());
    expect(current.tracks[1].source, MusicSource.wy);
    expect(current.tracks.last.source, MusicSource.tx);
    expect(current.customTrackOrder, originals.reversed.map((e) => e.identityKey));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancel or leave saved rematch never persists pending results', (tester) async {
    tester.view.physicalSize = const Size(980, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var pending = Completer<List<MusicInfo>>();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerControllerProvider.overrideWith((ref) => throw StateError('Must not access queue')),
      spotifyPlaylistImporterProvider.overrideWithValue(SpotifyPlaylistImporter(
        loadPage: (_) => throw StateError('No remote read'),
        enabledPlatforms: () async => [MusicSource.wy],
        search: (_, _) => pending.future,
      )),
    ]);
    addTearDown(container.dispose);
    final saved = await container.read(localPlaylistsProvider.notifier).importSpotify(preview([row(0)]));
    final router = GoRouter(initialLocation: '/home', routes: [
      GoRoute(path: '/home', builder: (_, _) => const Text('Home')),
      GoRoute(path: '/playlists/import', builder: (_, _) => const OnlinePlaylistImportPage()),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp.router(routerConfig: router)));
    router.push('/playlists/import?rematch=${saved.id}');
    await tester.pumpAndSettle();
    await tester.tap(find.text('补配未匹配项'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    pending.complete([candidate(MusicSource.wy)]);
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider).single.toJson(), saved.toJson());
    pending = Completer<List<MusicInfo>>();
    await tester.tap(find.text('补配未匹配项'));
    await tester.pump();
    router.pop();
    await tester.pumpAndSettle();
    pending.complete([candidate(MusicSource.wy)]);
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider).single.toJson(), saved.toJson());
    expect(tester.takeException(), isNull);
  });

  test('saved patch rejects concurrent deletion and never restores deleted entries', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    final store = container.read(localPlaylistsProvider.notifier);
    final original = [row(0), row(1)];
    final saved = await store.importSpotify(preview(original));
    await store.removeTracks(saved.id, [original.last.identityKey]);
    await expectLater(store.patchSpotifyMatches(saved.id, snapshot: original,
      replacements: [for (final track in original) PlaylistTrack.fromSpotify(track.spotify!, candidate(MusicSource.tx))]),
      throwsA(isA<PlaylistStoreException>()));
    expect(container.read(localPlaylistsProvider).single.tracks.map((e) => e.identityKey), [original.first.identityKey]);
  });
}
