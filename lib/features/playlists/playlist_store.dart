import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/models/playlist_info.dart';
import '../../core/storage/settings_store.dart';
import '../downloads/download_history_store.dart';
import 'lx_playlist_import.dart';
import 'playlist_models.dart';
import 'spotify_playlist_import.dart';

const String localPlaylistsStorageKey = 'local_playlists_v1';

class PlaylistStoreException implements Exception {
  const PlaylistStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalPlaylistNotifier extends Notifier<List<LocalPlaylist>> {
  late SharedPreferences _prefs;
  int _idSequence = 0;

  @override
  List<LocalPlaylist> build() {
    _prefs = ref.read(sharedPreferencesProvider);
    return _decodeStoredPlaylists(_prefs.get(localPlaylistsStorageKey));
  }

  LocalPlaylist? byId(String id) {
    for (final playlist in state) {
      if (playlist.id == id) return playlist;
    }
    return null;
  }

  Future<LocalPlaylist> create(String name) async {
    final normalizedName = _validatedUniqueName(name);
    final now = DateTime.now();
    final playlist = LocalPlaylist(
      id: _newId(),
      name: normalizedName,
      tracks: const [],
      createdAt: now,
      updatedAt: now,
    );
    state = List<LocalPlaylist>.unmodifiable([...state, playlist]);
    await _persist();
    return playlist;
  }

  Future<bool> rename(String id, String name) async {
    final index = state.indexWhere((playlist) => playlist.id == id);
    if (index < 0) return false;
    final normalizedName = _validatedUniqueName(name, excludingId: id);
    if (state[index].name == normalizedName) return true;

    final next = [...state];
    next[index] = state[index].copyWith(
      name: normalizedName,
      updatedAt: DateTime.now(),
    );
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return true;
  }

  Future<void> setPlaylistOrder(List<String> playlistIds) async {
    final byId = {for (final playlist in state) playlist.id: playlist};
    final requested = playlistIds.toSet();
    if (playlistIds.length != byId.length ||
        requested.length != playlistIds.length ||
        !requested.containsAll(byId.keys)) {
      throw const PlaylistStoreException('歌单列表已变化，请重新整理');
    }
    if (listEquals(
      state.map((playlist) => playlist.id).toList(),
      playlistIds,
    )) {
      return;
    }
    state = List<LocalPlaylist>.unmodifiable(
      playlistIds.map((id) => byId[id]!),
    );
    await _persist();
  }

  Future<void> setCustomTrackOrder(
    String playlistId,
    List<String> trackIds,
  ) async {
    final index = state.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) throw const PlaylistStoreException('歌单不存在');
    final current = state[index];
    final ids = {for (final track in current.tracks) track.identityKey};
    final requested = trackIds.toSet();
    if (trackIds.length != current.tracks.length ||
        requested.length != trackIds.length ||
        !requested.containsAll(ids)) {
      throw const PlaylistStoreException('歌单歌曲已变化，请重新整理');
    }
    final next = [...state];
    next[index] = current.copyWith(
      customTrackOrder: trackIds,
      updatedAt: DateTime.now(),
    );
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
  }

  Future<int> patchSpotifyMatches(
    String playlistId, {
    required List<PlaylistTrack> snapshot,
    required List<PlaylistTrack> replacements,
  }) async {
    final index = state.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) throw const PlaylistStoreException('歌单不存在');
    final current = state[index];
    final before = {for (final track in snapshot) track.identityKey: track};
    final after = {for (final track in replacements) track.identityKey: track};
    final ids = current.tracks.map((track) => track.identityKey).toSet();
    if (before.length != snapshot.length ||
        after.length != replacements.length ||
        ids.length != current.tracks.length ||
        ids.length != before.length ||
        !ids.containsAll(before.keys) ||
        after.length != before.length ||
        !ids.containsAll(after.keys)) {
      throw const PlaylistStoreException('歌单歌曲已变化，请重新补配');
    }
    var changed = 0;
    final tracks = <PlaylistTrack>[];
    for (final track in current.tracks) {
      final snapshot = before[track.identityKey]!;
      final replacement = after[track.identityKey]!;
      final updated = track.spotifyMatchReplacement(
        snapshot: snapshot,
        replacement: replacement,
      );
      if (updated != null) {
        changed++;
      } else if (replacement.spotifyMatchIsManual &&
          !snapshot.hasSameSpotifyMatch(replacement) &&
          !track.hasSameSpotifyMatch(replacement)) {
        throw const PlaylistStoreException('歌曲匹配已更新，请重新打开歌单后再补配');
      }
      tracks.add(updated ?? track);
    }
    if (changed == 0) return 0;
    final next = [...state];
    next[index] = current.copyWith(tracks: tracks, updatedAt: DateTime.now());
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return changed;
  }

  Future<bool> setSpotifyTrackMatch(
    String playlistId, {
    required PlaylistTrack expected,
    required MusicInfo music,
  }) async {
    final index = state.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0 || expected.spotify == null) return false;
    final current = state[index];
    final trackIndex = current.tracks.indexWhere(
      (track) => track.identityKey == expected.identityKey,
    );
    if (trackIndex < 0) return false;
    final track = current.tracks[trackIndex];
    if (track.spotify == null) return false;
    final replacement = expected.withSpotifyMatch(music);
    final updated = track.spotifyMatchReplacement(
      snapshot: expected,
      replacement: replacement,
    );
    if (updated == null) return track.hasSameSpotifyMatch(replacement);
    final tracks = [...current.tracks]..[trackIndex] = updated;
    final next = [...state];
    next[index] = current.copyWith(tracks: tracks, updatedAt: DateTime.now());
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return true;
  }

  Future<bool> delete(String id) async {
    final next = state.where((playlist) => playlist.id != id).toList();
    if (next.length == state.length) return false;
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return true;
  }

  Future<int> addTrack(String playlistId, DownloadHistoryEntry entry) {
    return addTracks(playlistId, [entry]);
  }

  Future<int> addEntry(String playlistId, DownloadHistoryEntry entry) {
    return addTrack(playlistId, entry);
  }

  Future<int> addTracks(
    String playlistId,
    Iterable<DownloadHistoryEntry> entries,
  ) async {
    final candidates = <PlaylistTrack>[];
    for (final entry in entries) {
      if (!entry.isCompleted || entry.savedPath?.trim().isEmpty != false) {
        continue;
      }
      candidates.add(PlaylistTrack.fromDownloadHistory(entry));
    }
    return _mergeTracks(playlistId, candidates);
  }

  Future<int> addEntries(
    String playlistId,
    Iterable<DownloadHistoryEntry> entries,
  ) {
    return addTracks(playlistId, entries);
  }

  Future<int> addMusic(String playlistId, MusicInfo music) {
    return addMusics(playlistId, [music]);
  }

  Future<int> addMusics(String playlistId, Iterable<MusicInfo> musics) {
    return _mergeTracks(playlistId, musics.map(PlaylistTrack.fromMusicInfo));
  }

  Future<LocalPlaylist> importOnline(
    PlaylistInfo online, {
    bool synchronizeTracks = false,
  }) {
    return _importOnlineTracks(
      originId: online.id.trim(),
      sourceCode: online.source.code,
      name: online.name,
      importedTracks: online.tracks.map(PlaylistTrack.fromMusicInfo).toList(),
      coverUrl: online.coverUrl,
      creator: online.creator,
      description: online.description,
      synchronizeTracks: synchronizeTracks,
    );
  }

  Future<LocalPlaylist> importSpotify(
    SpotifyPlaylistPreview preview, {
    Map<String, PlaylistTrack> manualMatchSnapshots = const {},
  }) async {
    final current = state
        .where(
          (playlist) =>
              playlist.originPlaylistId == preview.id &&
              playlist.originSourceCode == 'spotify',
        )
        .firstOrNull;
    final manualMatches = {
      for (final track in current?.tracks ?? <PlaylistTrack>[])
        if (track.spotifyMatchIsManual) track.identityKey: track,
    };
    final tracks = preview.tracks.map((incoming) {
      final saved = manualMatches[incoming.identityKey];
      if (saved == null ||
          !incoming.spotifyMatchIsManual ||
          saved.hasSameSpotifyMatch(incoming)) {
        return incoming;
      }
      final snapshot = manualMatchSnapshots[incoming.identityKey];
      if (snapshot != null) {
        if (saved.hasSameSpotifyMatch(snapshot)) return incoming;
        throw const PlaylistStoreException('歌曲匹配已更新，请重新解析后再保存');
      }
      return saved.copyWith(
        name: incoming.name,
        singer: incoming.singer,
        spotify: incoming.spotify,
      );
    }).toList();
    return _importOnlineTracks(
      originId: preview.id,
      sourceCode: 'spotify',
      name: preview.name,
      importedTracks: tracks,
      creator: preview.creator,
      coverUrl: preview.coverUrl,
      originTrackCount: preview.total,
      synchronizeTracks: true,
      preserveUnseenTracks: !preview.complete,
    );
  }

  Future<LocalPlaylist> _importOnlineTracks({
    required String originId,
    required String sourceCode,
    required String name,
    required List<PlaylistTrack> importedTracks,
    int? originTrackCount,
    bool preserveUnseenTracks = false,
    required bool synchronizeTracks,
    String? coverUrl,
    String? creator,
    String? description,
  }) async {
    final onlineTrackIds = _uniqueTrackIds(importedTracks);
    final existingIndex = state.indexWhere(
      (playlist) =>
          originId.isNotEmpty &&
          playlist.originPlaylistId == originId &&
          playlist.originSourceCode == sourceCode,
    );

    if (existingIndex >= 0) {
      final current = state[existingIndex];
      final movedOut = current.movedOutTrackIds?.toSet() ?? const <String>{};
      final availableTracks = importedTracks.where(
        (track) => !movedOut.contains(track.identityKey),
      );
      // A partial Spotify preview only establishes the order of the visible prefix.
      final refreshedTracks = availableTracks.toList();
      if (preserveUnseenTracks) {
        final visible = onlineTrackIds.toSet();
        final previous = current.onlineTrackIds?.toSet();
        for (final track in current.tracks) {
          if ((previous?.contains(track.identityKey) ??
                  track.spotify != null) &&
              !visible.contains(track.identityKey) &&
              !movedOut.contains(track.identityKey)) {
            refreshedTracks.add(track);
          }
        }
      }
      final tracks = synchronizeTracks
          ? _synchronizeTrackLists(
              current.tracks,
              refreshedTracks,
              previousOnlineTrackIds: current.onlineTrackIds,
            )
          : _mergeTrackLists(current.tracks, availableTracks).tracks;
      final storedOnlineTrackIds = synchronizeTracks
          ? _mergeOnlineTrackIds(
              onlineTrackIds,
              _uniqueTrackIds(refreshedTracks),
            )
          : _mergeOnlineTrackIds(current.onlineTrackIds, onlineTrackIds);
      final updated = LocalPlaylist(
        id: current.id,
        name: current.name,
        tracks: tracks,
        createdAt: current.createdAt,
        updatedAt: DateTime.now(),
        originPlaylistId: originId,
        originSourceCode: sourceCode,
        onlineTrackIds: storedOnlineTrackIds,
        movedOutTrackIds: current.movedOutTrackIds,
        movedOutTrackProviders: current.movedOutTrackProviders,
        customTrackOrder: current.copyWith(tracks: tracks).customTrackOrder,
        originTrackCount: originTrackCount,
        originPreviewCount: sourceCode == 'spotify'
            ? importedTracks.length
            : null,
        coverUrl: _nonEmpty(coverUrl) ?? current.coverUrl,
        creator: _nonEmpty(creator) ?? current.creator,
        description: _nonEmpty(description) ?? current.description,
      );
      final next = [...state]..[existingIndex] = updated;
      state = List<LocalPlaylist>.unmodifiable(next);
      await _persist();
      return updated;
    }

    final now = DateTime.now();
    final imported = LocalPlaylist(
      id: _newId(prefix: 'online'),
      name: _uniqueImportedName(name),
      tracks: _mergeTrackLists(const [], importedTracks).tracks,
      createdAt: now,
      updatedAt: now,
      originPlaylistId: originId.isEmpty ? null : originId,
      originSourceCode: sourceCode,
      onlineTrackIds: onlineTrackIds,
      originTrackCount: originTrackCount,
      originPreviewCount: sourceCode == 'spotify'
          ? importedTracks.length
          : null,
      coverUrl: _nonEmpty(coverUrl),
      creator: _nonEmpty(creator),
      description: _nonEmpty(description),
    );
    state = List<LocalPlaylist>.unmodifiable([...state, imported]);
    await _persist();
    return imported;
  }

  Future<List<LocalPlaylist>> importLxPlaylists(
    Iterable<LxPlaylistData> sourcePlaylists,
  ) async {
    final values = sourcePlaylists.toList(growable: false);
    if (values.isEmpty) return const [];

    final next = state.toList();
    final imported = <LocalPlaylist>[];
    for (final sourcePlaylist in values) {
      final now = DateTime.now();
      final playlist = LocalPlaylist(
        id: _newId(prefix: 'lx'),
        name: _uniqueImportedName(sourcePlaylist.name, playlists: next),
        tracks: _mergeTrackLists(
          const [],
          sourcePlaylist.tracks.map(PlaylistTrack.fromMusicInfo),
        ).tracks,
        createdAt: now,
        updatedAt: now,
      );
      next.add(playlist);
      imported.add(playlist);
    }

    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return List<LocalPlaylist>.unmodifiable(imported);
  }

  List<Map<String, dynamic>> exportForSync() {
    return List<Map<String, dynamic>>.unmodifiable([
      for (final playlist in state)
        playlist
            .copyWith(
              tracks: [
                for (final track in playlist.tracks)
                  if (track.musicInfo != null || track.spotify != null)
                    track.withoutLocalPath(),
              ],
            )
            .toJson(),
    ]);
  }

  Future<void> applyFromSync(Object value) async {
    if (value is! List) throw const PlaylistStoreException('云端歌单格式无效');
    final incoming = <LocalPlaylist>[];
    final seenIds = <String>{};
    for (final item in value) {
      final playlist = LocalPlaylist.tryFromJson(item);
      if (playlist == null || !seenIds.add(playlist.id)) {
        throw const PlaylistStoreException('云端歌单包含无效或重复的数据');
      }
      incoming.add(playlist);
    }

    final currentById = {for (final playlist in state) playlist.id: playlist};
    final restored = <LocalPlaylist>[];
    for (final remote in incoming) {
      final current = currentById[remote.id];
      if (current == null) {
        restored.add(remote);
        continue;
      }
      final sameOrigin =
          remote.originPlaylistId == current.originPlaylistId &&
          remote.originSourceCode == current.originSourceCode;
      // Legacy payloads omit move history. An empty list explicitly clears it.
      final movedOutTrackIds =
          remote.movedOutTrackIds ??
          (sameOrigin ? current.movedOutTrackIds : null);
      final movedOutTrackProviders =
          remote.movedOutTrackIds == null && sameOrigin
          ? current.movedOutTrackProviders
          : remote.movedOutTrackProviders;
      final movedOut = movedOutTrackIds?.toSet() ?? const <String>{};
      final currentByTrack = {
        for (final track in current.tracks) track.identityKey: track,
      };
      final remoteIds = {for (final track in remote.tracks) track.identityKey};
      final localOnly = [
        for (final track in current.tracks)
          if (track.musicInfo == null &&
              track.isLocal &&
              !movedOut.contains(track.identityKey) &&
              !remoteIds.contains(track.identityKey))
            track,
      ];
      final portable = [
        for (final track in remote.tracks)
          if (!movedOut.contains(track.identityKey))
            currentByTrack[track.identityKey]?.mergePreferLocal(track) ?? track,
      ];
      final tracks = List<PlaylistTrack>.unmodifiable([
        ...localOnly,
        ...portable,
      ]);
      restored.add(
        remote.copyWith(
          tracks: tracks,
          customTrackOrder: remote.customTrackOrder ?? current.customTrackOrder,
          movedOutTrackIds: movedOutTrackIds,
          movedOutTrackProviders: movedOutTrackProviders,
        ),
      );
    }
    state = List<LocalPlaylist>.unmodifiable(restored);
    await _persist();
  }

  Future<bool> updateTrackCover({
    required String playlistId,
    required String trackId,
    required String picUrl,
    MusicInfo? expectedMusic,
  }) async {
    final url = picUrl.trim();
    if (url.isEmpty) return false;

    final playlistIndex = state.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (playlistIndex < 0) return false;

    final playlist = state[playlistIndex];
    final trackIndex = playlist.tracks.indexWhere(
      (track) => track.identityKey == trackId,
    );
    if (trackIndex < 0) return false;

    final current = playlist.tracks[trackIndex];
    if (expectedMusic != null &&
        (expectedMusic.id != current.musicId ||
            expectedMusic.source != current.source)) {
      return false;
    }
    final musicJson = _musicJsonWithPicUrl(current.musicJson, url);
    final currentMetaPicUrl = _musicJsonPicUrl(current.musicJson);
    if (current.picUrl == url &&
        (current.musicJson == null || currentMetaPicUrl == url)) {
      return false;
    }

    final tracks = playlist.tracks.toList();
    tracks[trackIndex] = current.copyWith(picUrl: url, musicJson: musicJson);
    final playlists = state.toList();
    playlists[playlistIndex] = playlist.copyWith(
      tracks: List<PlaylistTrack>.unmodifiable(tracks),
      updatedAt: DateTime.now(),
    );
    state = List<LocalPlaylist>.unmodifiable(playlists);
    await _persist();
    return true;
  }

  Future<bool> removeTrack(String playlistId, String trackId) async {
    return await removeTracks(playlistId, [trackId]) > 0;
  }

  Future<int> removeTracks(String playlistId, Iterable<String> trackIds) async {
    final index = state.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return 0;
    final keys = trackIds.toSet();
    if (keys.isEmpty) return 0;

    final current = state[index];
    final tracks = current.tracks
        .where((track) => !keys.contains(track.identityKey))
        .toList(growable: false);
    final removed = current.tracks.length - tracks.length;
    if (removed == 0) return 0;

    final next = [...state];
    next[index] = current.copyWith(
      tracks: List<PlaylistTrack>.unmodifiable(tracks),
      updatedAt: DateTime.now(),
    );
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return removed;
  }

  Future<int> transferPlaylistTracks({
    required String fromPlaylistId,
    required String toPlaylistId,
    required Iterable<String> trackIds,
    required bool move,
  }) async {
    if (fromPlaylistId == toPlaylistId) return 0;
    final sourceIndex = state.indexWhere((p) => p.id == fromPlaylistId);
    final targetIndex = state.indexWhere((p) => p.id == toPlaylistId);
    if (sourceIndex < 0 || targetIndex < 0) return 0;

    final source = state[sourceIndex];
    final target = state[targetIndex];
    final requested = trackIds.toSet();
    final selected = source.customOrderedTracks
        .where((track) => requested.contains(track.identityKey))
        .toList(growable: false);
    if (selected.isEmpty) return 0;

    final entryKeys = <String>{};
    final resourceKeys = <String>{};
    final unresolvedKeys = <String>{};
    void index(PlaylistTrack track) {
      final canonicalKey = track.canonicalIdentityKey;
      final providerKey = track.providerIdentityKey;
      final fileKey = track.localFileIdentityKey;
      entryKeys.add(track.identityKey);
      if (providerKey == null) {
        unresolvedKeys.add(canonicalKey);
      } else {
        resourceKeys.add(providerKey);
      }
      if (fileKey != null) resourceKeys.add(fileKey);
    }

    target.tracks.forEach(index);
    final added = <PlaylistTrack>[];
    for (final track in selected) {
      final canonicalKey = track.canonicalIdentityKey;
      final providerKey = track.providerIdentityKey;
      if (resourceKeys.contains(providerKey) ||
          resourceKeys.contains(track.localFileIdentityKey) ||
          (providerKey == null && unresolvedKeys.contains(canonicalKey))) {
        continue;
      }

      // A moved-out Spotify original can reclaim its entry alongside another match.
      final reservedProviders = target.movedOutTrackProviders;
      final reservedForAnotherVersion =
          (reservedProviders?.containsKey(canonicalKey) ?? false) &&
          reservedProviders![canonicalKey] != providerKey;
      var entryKey = canonicalKey;
      if (entryKeys.contains(entryKey) || reservedForAnotherVersion) {
        final base = 'entry:${jsonEncode([canonicalKey, providerKey])}';
        entryKey = base;
        for (var suffix = 2; entryKeys.contains(entryKey); suffix++) {
          entryKey = '$base:$suffix';
        }
      }
      final entry = track.identityKey == entryKey
          ? track
          : track.copyWith(playlistEntryKey: entryKey);
      index(entry);
      added.add(entry);
    }
    if (added.isEmpty && !move) return 0;

    final now = DateTime.now();
    final next = [...state];
    if (added.isNotEmpty) {
      final history = _movedOutAfterAdding(target, added);
      next[targetIndex] = target.copyWith(
        tracks: List<PlaylistTrack>.unmodifiable([...added, ...target.tracks]),
        movedOutTrackIds: history?.ids,
        movedOutTrackProviders: history?.providers,
        updatedAt: now,
      );
    }
    if (move) {
      final history = _movedOutAfterMoving(source, selected);
      next[sourceIndex] = source.copyWith(
        tracks: List<PlaylistTrack>.unmodifiable(
          source.tracks.where(
            (track) => !requested.contains(track.identityKey),
          ),
        ),
        movedOutTrackIds: history?.ids,
        movedOutTrackProviders: history?.providers,
        updatedAt: now,
      );
    }
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return move ? selected.length : added.length;
  }

  Future<int> removeLocalPathFromAll(String path) async {
    final normalizedPath = normalizePlaylistPath(path);
    var affected = 0;
    var changed = false;
    final now = DateTime.now();
    final next = <LocalPlaylist>[];
    for (final playlist in state) {
      var playlistChanged = false;
      final tracks = <PlaylistTrack>[];
      for (final track in playlist.tracks) {
        final localPath = track.localPath;
        final matches =
            localPath != null &&
            normalizePlaylistPath(localPath) == normalizedPath;
        if (!matches) {
          tracks.add(track);
          continue;
        }

        affected++;
        playlistChanged = true;
        final onlineFallback = track.withoutLocalPath();
        if (onlineFallback.musicInfo != null) tracks.add(onlineFallback);
      }
      if (!playlistChanged) {
        next.add(playlist);
      } else {
        changed = true;
        next.add(
          playlist.copyWith(
            tracks: List<PlaylistTrack>.unmodifiable(tracks),
            updatedAt: now,
          ),
        );
      }
    }
    if (!changed) return 0;
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return affected;
  }

  Future<int> attachDownload({
    required MusicInfo music,
    required Quality quality,
    required String localPath,
  }) async {
    final path = localPath.trim();
    if (path.isEmpty) return 0;

    final downloaded = PlaylistTrack.fromMusicInfo(
      music,
    ).copyWith(qualityCode: quality.code, localPath: path);
    final identityKey = downloaded.identityKey;
    final now = DateTime.now();
    var attached = 0;
    final next = <LocalPlaylist>[];

    for (final playlist in state) {
      var playlistChanged = false;
      final tracks = <PlaylistTrack>[];
      for (final track in playlist.tracks) {
        if (track.identityKey != identityKey &&
            !(track.spotify != null &&
                track.sourceCode == music.source.code &&
                track.musicId == music.id)) {
          tracks.add(track);
          continue;
        }

        final updated = track.spotify != null
            ? track.copyWith(localPath: path, qualityCode: quality.code)
            : track.mergePreferLocal(downloaded);
        tracks.add(updated);
        if (!_sameTrackSnapshot(track, updated)) {
          playlistChanged = true;
          attached++;
        }
      }

      next.add(
        playlistChanged
            ? playlist.copyWith(
                tracks: List<PlaylistTrack>.unmodifiable(tracks),
                updatedAt: now,
              )
            : playlist,
      );
    }

    if (attached == 0) return 0;
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return attached;
  }

  Future<int> _mergeTracks(
    String playlistId,
    Iterable<PlaylistTrack> candidates,
  ) async {
    final index = state.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return 0;
    final current = state[index];
    final merged = _mergeTrackLists(
      current.tracks,
      candidates,
      prependNew: true,
    );
    if (!merged.changed) return 0;

    final history = _movedOutAfterAdding(current, candidates);
    final next = [...state];
    next[index] = current.copyWith(
      tracks: merged.tracks,
      movedOutTrackIds: history?.ids,
      movedOutTrackProviders: history?.providers,
      updatedAt: DateTime.now(),
    );
    state = List<LocalPlaylist>.unmodifiable(next);
    await _persist();
    return merged.added;
  }

  String _validatedUniqueName(String value, {String? excludingId}) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const PlaylistStoreException('歌单名称不能为空');
    }
    final folded = normalized.toLowerCase();
    final duplicate = state.any(
      (playlist) =>
          playlist.id != excludingId && playlist.name.toLowerCase() == folded,
    );
    if (duplicate) throw const PlaylistStoreException('已存在同名歌单');
    return normalized;
  }

  String _uniqueImportedName(
    String value, {
    Iterable<LocalPlaylist>? playlists,
  }) {
    final base = value.trim().isEmpty ? '导入的歌单' : value.trim();
    final used = {
      for (final playlist in playlists ?? state) playlist.name.toLowerCase(),
    };
    if (!used.contains(base.toLowerCase())) return base;
    var suffix = 2;
    while (used.contains('$base ($suffix)'.toLowerCase())) {
      suffix++;
    }
    return '$base ($suffix)';
  }

  String _newId({String prefix = 'local'}) {
    String id;
    do {
      id = '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_idSequence++}';
    } while (state.any((playlist) => playlist.id == id));
    return id;
  }

  Future<void> _persist() {
    final rows = [for (final playlist in state) jsonEncode(playlist.toJson())];
    return _prefs.setStringList(localPlaylistsStorageKey, rows);
  }
}

final localPlaylistsProvider =
    NotifierProvider<LocalPlaylistNotifier, List<LocalPlaylist>>(
      LocalPlaylistNotifier.new,
    );

final playlistStoreProvider = localPlaylistsProvider;

List<LocalPlaylist> _decodeStoredPlaylists(Object? stored) {
  final values = <Object?>[];
  if (stored is List) {
    values.addAll(stored);
  } else if (stored is String) {
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) {
        values.addAll(decoded);
      } else {
        values.add(decoded);
      }
    } catch (_) {
      return const [];
    }
  } else {
    return const [];
  }

  final playlists = <LocalPlaylist>[];
  final seenIds = <String>{};
  for (final value in values) {
    Object? decoded = value;
    if (value is String) {
      try {
        decoded = jsonDecode(value);
      } catch (_) {
        continue;
      }
    }
    final playlist = LocalPlaylist.tryFromJson(decoded);
    if (playlist != null && seenIds.add(playlist.id)) {
      playlists.add(playlist);
    }
  }
  return List<LocalPlaylist>.unmodifiable(playlists);
}

_TrackMergeResult _mergeTrackLists(
  Iterable<PlaylistTrack> current,
  Iterable<PlaylistTrack> incoming, {
  bool prependNew = false,
}) {
  final tracks = current.toList();
  final currentLength = tracks.length;
  final indexByKey = <String, int>{
    for (var index = 0; index < tracks.length; index++)
      tracks[index].identityKey: index,
  };
  var added = 0;
  var changed = false;
  for (final track in incoming) {
    final key = track.identityKey;
    final existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = tracks.length;
      tracks.add(track);
      added++;
      changed = true;
    } else {
      final merged = tracks[existingIndex].mergePreferLocal(track);
      if (!_sameTrackSnapshot(tracks[existingIndex], merged)) {
        tracks[existingIndex] = merged;
        changed = true;
      }
    }
  }
  final orderedTracks = prependNew && added > 0
      ? <PlaylistTrack>[
          ...tracks.skip(currentLength),
          ...tracks.take(currentLength),
        ]
      : tracks;
  return _TrackMergeResult(
    List<PlaylistTrack>.unmodifiable(orderedTracks),
    added: added,
    changed: changed,
  );
}

List<PlaylistTrack> _synchronizeTrackLists(
  Iterable<PlaylistTrack> current,
  Iterable<PlaylistTrack> incoming, {
  Iterable<String>? previousOnlineTrackIds,
}) {
  final currentTracks = current.toList(growable: false);
  final currentByKey = {
    for (final track in currentTracks) track.identityKey: track,
  };
  final incomingTracks = incoming.toList(growable: false);
  final incomingTrackIds = {
    for (final track in incomingTracks) track.identityKey,
  };
  final previousOnlineIds = previousOnlineTrackIds?.toSet();
  final synchronized = <PlaylistTrack>[];
  final indexByKey = <String, int>{};

  // Songs outside the previous remote snapshot were added locally. Keep them
  // above the freshly synchronized online tracks. Old stored playlists do not
  // have a snapshot; for their first update, conservatively retain any song
  // that cannot be matched to the latest remote response.
  for (final track in currentTracks) {
    final key = track.identityKey;
    final locallyAdded = previousOnlineIds == null
        ? !incomingTrackIds.contains(key)
        : !previousOnlineIds.contains(key);
    if (!locallyAdded || indexByKey.containsKey(key)) continue;
    indexByKey[key] = synchronized.length;
    synchronized.add(track);
  }

  for (final track in incomingTracks) {
    final key = track.identityKey;
    final existing = currentByKey[key];
    final refreshed = existing?.mergePreferLocal(track) ?? track;
    final synchronizedIndex = indexByKey[key];
    if (synchronizedIndex == null) {
      indexByKey[key] = synchronized.length;
      synchronized.add(refreshed);
    } else {
      synchronized[synchronizedIndex] = synchronized[synchronizedIndex]
          .mergePreferLocal(refreshed);
    }
  }
  return List<PlaylistTrack>.unmodifiable(synchronized);
}

typedef _MovedOutTracks = ({List<String> ids, Map<String, String?> providers});

_MovedOutTracks? _movedOutAfterAdding(
  LocalPlaylist playlist,
  Iterable<PlaylistTrack> added,
) {
  final movedOut = playlist.movedOutTrackIds;
  if (movedOut == null || movedOut.isEmpty) return null;
  final addedIds = {for (final track in added) track.identityKey};
  final providers = {...?playlist.movedOutTrackProviders}
    ..removeWhere((id, _) => addedIds.contains(id));
  return (
    ids: movedOut.where((id) => !addedIds.contains(id)).toList(),
    providers: providers,
  );
}

_MovedOutTracks? _movedOutAfterMoving(
  LocalPlaylist playlist,
  Iterable<PlaylistTrack> moved,
) {
  if (playlist.onlinePlaylistId == null) return null;
  final snapshot = playlist.onlineTrackIds?.toSet();
  final onlineSource = playlist.onlineSource;
  final spotify = playlist.originSourceCode == 'spotify';
  final movedOut = <String>{...?playlist.movedOutTrackIds};
  final providers = {...?playlist.movedOutTrackProviders};
  for (final track in moved) {
    // Older imports have no remote snapshot. Infer membership from the origin.
    final belongsToOrigin =
        snapshot?.contains(track.identityKey) ??
        (spotify
            ? track.spotify != null &&
                  track.identityKey == track.canonicalIdentityKey
            : onlineSource != null &&
                  track.spotify == null &&
                  track.source == onlineSource);
    if (!belongsToOrigin) continue;
    movedOut.add(track.identityKey);
    if (spotify) {
      providers[track.identityKey] = track.providerIdentityKey;
    }
  }
  return movedOut.isEmpty
      ? null
      : (ids: movedOut.toList(), providers: providers);
}

List<String> _uniqueTrackIds(Iterable<PlaylistTrack> tracks) {
  final ids = <String>[];
  final seen = <String>{};
  for (final track in tracks) {
    if (seen.add(track.identityKey)) ids.add(track.identityKey);
  }
  return List<String>.unmodifiable(ids);
}

List<String> _mergeOnlineTrackIds(
  Iterable<String>? current,
  Iterable<String> incoming,
) {
  if (current == null) return List<String>.unmodifiable(incoming);
  final ids = <String>[];
  final seen = <String>{};
  for (final id in [...current, ...incoming]) {
    if (seen.add(id)) ids.add(id);
  }
  return List<String>.unmodifiable(ids);
}

bool _sameTrackSnapshot(PlaylistTrack left, PlaylistTrack right) {
  return jsonEncode(left.toJson()) == jsonEncode(right.toJson());
}

class _TrackMergeResult {
  const _TrackMergeResult(
    this.tracks, {
    required this.added,
    required this.changed,
  });

  final List<PlaylistTrack> tracks;
  final int added;
  final bool changed;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Map<String, dynamic>? _musicJsonWithPicUrl(
  Map<String, dynamic>? source,
  String picUrl,
) {
  if (source == null) return null;
  final json = Map<String, dynamic>.from(source);
  final rawMeta = json['meta'];
  final meta = rawMeta is Map
      ? Map<String, dynamic>.from(rawMeta)
      : <String, dynamic>{};
  meta['picUrl'] = picUrl;
  json['meta'] = meta;
  return json;
}

String? _musicJsonPicUrl(Map<String, dynamic>? source) {
  final meta = source?['meta'];
  if (meta is! Map) return null;
  final value = meta['picUrl'];
  return value is String ? value : null;
}
