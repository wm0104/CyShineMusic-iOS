import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/playlist_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_history_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/spotify_playlist_import.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late ProviderContainer container;
  late LocalPlaylistNotifier store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = _container(prefs);
    store = container.read(localPlaylistsProvider.notifier);
  });
  tearDown(() => container.dispose());

  test('custom order persists separately from the original track array', () async {
    final playlist = await store.create('Mine');
    await store.addMusics(playlist.id, [_music('a'), _music('b'), _music('c')]);
    final original = store.byId(playlist.id)!.tracks.map((t) => t.id).toList();
    await store.setCustomTrackOrder(playlist.id, [_id('c'), _id('a'), _id('b')]);
    expect(store.byId(playlist.id)!.tracks.map((t) => t.id), original);
    expect(_ordered(store.byId(playlist.id)!), ['c', 'a', 'b']);
    await store.rename(playlist.id, 'Renamed');
    container.dispose();
    container = _container(prefs);
    store = container.read(localPlaylistsProvider.notifier);
    final restored = store.byId(playlist.id)!;
    expect(_ordered(restored), ['c', 'a', 'b']);
    expect(restored.tracks.map((t) => t.id), original);
    expect(restored.name, 'Renamed');
  });

  test('invalid, foreign and stale drafts do not change or persist state', () async {
    final playlist = await store.create('Mine');
    final other = await store.create('Other');
    await store.addMusics(playlist.id, [_music('a'), _music('b')]);
    await store.addMusic(other.id, _music('foreign'));
    await store.setCustomTrackOrder(playlist.id, [_id('b'), _id('a')]);
    for (final draft in <List<String>>[
      [], [_id('a')], [_id('a'), _id('a')],
      [_id('a'), _id('foreign')], [_id('a'), _id('b'), _id('extra')],
    ]) {
      final before = prefs.getStringList(localPlaylistsStorageKey);
      final snapshot = store.byId(playlist.id);
      await expectLater(store.setCustomTrackOrder(playlist.id, draft),
          throwsA(isA<PlaylistStoreException>()));
      expect(store.byId(playlist.id), same(snapshot));
      expect(prefs.getStringList(localPlaylistsStorageKey), before);
    }
    final stale = [_id('b'), _id('a')];
    await store.addMusic(playlist.id, _music('new'));
    final before = prefs.getStringList(localPlaylistsStorageKey);
    await expectLater(store.setCustomTrackOrder(playlist.id, stale),
        throwsA(isA<PlaylistStoreException>()));
    await expectLater(store.setCustomTrackOrder('missing', []),
        throwsA(isA<PlaylistStoreException>()));
    expect(prefs.getStringList(localPlaylistsStorageKey), before);
    expect(_ordered(store.byId(playlist.id)!), ['b', 'a', 'new']);
    expect(store.byId(other.id)!.customTrackOrder, isNull);
  });

  test('empty custom order is enabled and survives JSON and later addition', () async {
    final playlist = await store.create('Empty');
    await store.setCustomTrackOrder(playlist.id, []);
    final restored = LocalPlaylist.tryFromJson(store.byId(playlist.id)!.toJson())!;
    expect(restored.customTrackOrder, isEmpty);
    expect(restored.customTrackOrder, isNotNull);
    await store.addMusic(playlist.id, _music('a'));
    expect(_ordered(store.byId(playlist.id)!), ['a']);
    final legacy = store.byId(playlist.id)!.toJson()..remove('customTrackOrder');
    expect(LocalPlaylist.tryFromJson(legacy)!.customTrackOrder, isNull);
  });

  test('append, deletion and re-add preserve relative order without resurrection', () async {
    final playlist = await store.create('Mine');
    await store.addMusics(playlist.id, [_music('a'), _music('b'), _music('c')]);
    final draft = [_id('c'), _id('a'), _id('b')];
    await store.setCustomTrackOrder(playlist.id, draft);
    draft.clear();
    await store.addMusic(playlist.id, _music('d'));
    expect(_ordered(store.byId(playlist.id)!), ['c', 'a', 'b', 'd']);
    expect(store.byId(playlist.id)!.tracks.first.musicId, 'd');
    await store.removeTrack(playlist.id, _id('c'));
    expect(store.byId(playlist.id)!.customTrackOrder, isNot(contains(_id('c'))));
    await store.addMusic(playlist.id, _music('c'));
    expect(_ordered(store.byId(playlist.id)!), ['a', 'b', 'd', 'c']);
  });

  test('JSON ignores stale IDs, deduplicates, and appends missing base tracks', () async {
    final playlist = await store.create('JSON');
    await store.addMusics(playlist.id, [_music('a'), _music('b'), _music('c')]);
    final json = store.byId(playlist.id)!.toJson();
    json['customTrackOrder'] = [_id('c'), _id('gone'), _id('c')];
    final restored = LocalPlaylist.tryFromJson(json)!;
    expect(_ordered(restored), ['c', 'a', 'b']);
    expect(restored.tracks.map((t) => t.musicId), ['a', 'b', 'c']);
    expect(restored.copyWith(name: 'Copy').customTrackOrder,
        [_id('c'), _id('a'), _id('b')]);
  });

  test('online merge retains unseen tracks; full refresh prunes only upstream removals', () async {
    final playlist = await store.importOnline(_online(['a', 'b', 'c']));
    await store.setCustomTrackOrder(playlist.id, [_id('c'), _id('a'), _id('b')]);
    await store.attachDownload(music: _music('a'), quality: Quality.flac,
        localPath: '/music/a.flac');
    await store.addMusic(playlist.id, _music('local-added'));
    await store.importOnline(_online(['d', 'a']));
    expect(_ordered(store.byId(playlist.id)!), ['c', 'a', 'b', 'local-added', 'd']);
    expect(store.byId(playlist.id)!.tracks.singleWhere((t) => t.id == _id('a')).localPath,
        '/music/a.flac');
    final stale = store.byId(playlist.id)!.customTrackOrder!.toList();
    await store.importOnline(_online(['d', 'c', 'e']), synchronizeTracks: true);
    final refreshed = store.byId(playlist.id)!;
    expect(_ordered(refreshed), ['c', 'local-added', 'd', 'e']);
    expect(refreshed.tracks.map((t) => t.musicId), ['local-added', 'd', 'c', 'e']);
    final before = prefs.getStringList(localPlaylistsStorageKey);
    await expectLater(store.setCustomTrackOrder(playlist.id, stale),
        throwsA(isA<PlaylistStoreException>()));
    expect(prefs.getStringList(localPlaylistsStorageKey), before);
    await store.importOnline(_online(['a', 'd', 'c', 'e']), synchronizeTracks: true);
    expect(_ordered(store.byId(playlist.id)!), ['c', 'local-added', 'd', 'e', 'a']);
  });

  test('Spotify occurrences move independently; partial previews never prune unseen tracks', () async {
    final a0 = _spotify('a', 0);
    final a1 = _spotify('a', 1);
    final b = _spotify('b', 0);
    final c = _spotify('c', 0);
    final playlist = await store.importSpotify(_preview([a0, a1, b], total: 3));
    expect(a0.id, isNot(a1.id));
    await store.setCustomTrackOrder(playlist.id, [a1.id, b.id, a0.id]);
    await store.importSpotify(_preview([c, a0], total: 4));
    expect(store.byId(playlist.id)!.customOrderedTracks.map((t) => t.id),
        [a1.id, b.id, a0.id, c.id]);
    await store.importSpotify(_preview([c, a1, a0], total: 3));
    expect(store.byId(playlist.id)!.customOrderedTracks.map((t) => t.id),
        [a1.id, a0.id, c.id]);
    await store.importSpotify(_preview([b, c, a0, a1], total: 4));
    expect(store.byId(playlist.id)!.customOrderedTracks.map((t) => t.id),
        [a1.id, a0.id, c.id, b.id]);
    container.dispose();
    container = _container(prefs);
    store = container.read(localPlaylistsProvider.notifier);
    expect(store.byId(playlist.id)!.customOrderedTracks.map((t) => t.id),
        [a1.id, a0.id, c.id, b.id]);
  });

  test('WebDAV payload roundtrip restores remote custom order and keeps device files', () async {
    final playlist = await store.create('Sync');
    await store.addMusics(playlist.id, [_music('a'), _music('b')]);
    await store.addTrack(playlist.id, _localFile());
    final fileId = store.byId(playlist.id)!.tracks.first.id;
    await store.attachDownload(music: _music('a'), quality: Quality.flac,
        localPath: '/music/a.flac');
    await store.setCustomTrackOrder(playlist.id, [_id('b'), fileId, _id('a')]);
    final payload = jsonDecode(jsonEncode(store.exportForSync()));
    expect((payload as List).single['tracks'], hasLength(2));
    expect(jsonEncode(payload), isNot(contains('/music/')));

    // Use a fresh preference snapshot through the public Store to model another device.
    SharedPreferences.setMockInitialValues({});
    final remotePrefs = await SharedPreferences.getInstance();
    final fresh = _container(remotePrefs);
    try {
      final remote = fresh.read(localPlaylistsProvider.notifier);
      await remote.applyFromSync(payload);
      expect(_ordered(remote.byId(playlist.id)!), ['b', 'a']);
      await remote.setCustomTrackOrder(playlist.id, [_id('a'), _id('b')]);
      final back = jsonDecode(jsonEncode(remote.exportForSync()));
      await store.applyFromSync(back);
      final restored = store.byId(playlist.id)!;
      expect(_ordered(restored), ['a', 'b', 'file']);
      expect(restored.tracks.singleWhere((t) => t.id == fileId).localPath,
          '/music/file.flac');
      expect(restored.tracks.singleWhere((t) => t.id == _id('a')).localPath,
          '/music/a.flac');
    } finally {
      fresh.dispose();
    }
  });

  test('legacy sync retains local custom order but removes absent portable IDs', () async {
    final playlist = await store.create('Legacy');
    await store.addMusics(playlist.id, [_music('a'), _music('b'), _music('c')]);
    await store.addTrack(playlist.id, _localFile());
    final fileId = store.byId(playlist.id)!.tracks.first.id;
    await store.setCustomTrackOrder(playlist.id, [_id('c'), fileId, _id('a'), _id('b')]);
    final row = store.exportForSync().single;
    row.remove('customTrackOrder');
    row['tracks'] = [_trackJson('b'), _trackJson('a'), _trackJson('new')];
    await store.applyFromSync([row]);
    expect(_ordered(store.byId(playlist.id)!), ['file', 'a', 'b', 'new']);
    expect(store.byId(playlist.id)!.customTrackOrder, isNot(contains(_id('c'))));
    await store.addMusic(playlist.id, _music('c'));
    expect(_ordered(store.byId(playlist.id)!), ['file', 'a', 'b', 'new', 'c']);
  });

  test('removing a device-only file clears its custom ID', () async {
    final playlist = await store.create('File');
    await store.addMusic(playlist.id, _music('a'));
    await store.addTrack(playlist.id, _localFile());
    final fileId = store.byId(playlist.id)!.tracks.first.id;
    await store.setCustomTrackOrder(playlist.id, [fileId, _id('a')]);
    await store.removeLocalPathFromAll('/music/file.flac');
    expect(store.byId(playlist.id)!.customTrackOrder, [_id('a')]);
    await store.addTrack(playlist.id, _localFile());
    expect(_ordered(store.byId(playlist.id)!), ['a', 'file']);
  });
}

ProviderContainer _container(SharedPreferences prefs) => ProviderContainer(
  overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
);
String _id(String id) => 'music:wy:$id';
List<String> _ordered(LocalPlaylist playlist) =>
    playlist.customOrderedTracks.map((t) => t.musicId).toList();
MusicInfo _music(String id) => MusicInfo.fromJson({
  'id': id, 'name': id, 'singer': 'Artist', 'source': 'wy', 'interval': '03:30',
  'meta': {'songId': id, 'albumName': 'Album', 'qualitys': [{'type': '320k'}]},
});

PlaylistInfo _online(List<String> ids) => PlaylistInfo(
  id: 'remote', name: 'Online', source: MusicSource.wy,
  tracks: ids.map(_music).toList(),
);
PlaylistTrack _spotify(String id, int occurrence) => PlaylistTrack.fromSpotify(
  SpotifyTrackMetadata(uri: 'spotify:track:$id', title: id,
      artist: 'Artist', occurrence: occurrence),
  null,
);
SpotifyPlaylistPreview _preview(List<PlaylistTrack> tracks, {required int total}) =>
    SpotifyPlaylistPreview(id: 'spotify-playlist', name: 'Spotify',
        tracks: tracks, total: total);
Map<String, dynamic> _trackJson(String id) =>
    PlaylistTrack.fromMusicInfo(_music(id)).toJson();
DownloadHistoryEntry _localFile() => DownloadHistoryEntry(
  id: 'history-file', musicId: 'file', name: 'Device file', singer: 'Artist',
  albumName: '', sourceCode: MusicSource.all.code, qualityCode: Quality.flac.code,
  status: DownloadHistoryStatus.completed, createdAt: DateTime.utc(2026),
  savedPath: '/music/file.flac',
);
