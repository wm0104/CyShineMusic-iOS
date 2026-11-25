import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../downloads/download_history_store.dart';

@immutable
class SpotifyTrackMetadata {
  const SpotifyTrackMetadata({
    required this.uri,
    required this.title,
    required this.artist,
    required this.occurrence,
    this.durationMs,
    this.type = 'track',
    this.explicit,
  });

  final String uri;
  final String title;
  final String artist;
  final int occurrence;
  final int? durationMs;
  final String type;
  final bool? explicit;

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'title': title,
    'artist': artist,
    'occurrence': occurrence,
    'type': type,
    if (durationMs != null) 'durationMs': durationMs,
    if (explicit != null) 'explicit': explicit,
  };

  static SpotifyTrackMetadata? tryFromJson(Object? value) {
    final json = _mapOrNull(value);
    if (json == null || json['uri'] is! String || json['title'] is! String) {
      return null;
    }
    return SpotifyTrackMetadata(
      uri: json['uri'] as String,
      title: json['title'] as String,
      artist: _string(json['artist']),
      occurrence: json['occurrence'] is int ? json['occurrence'] as int : 0,
      type: _string(json['type'], fallback: 'track'),
      durationMs: json['durationMs'] is int ? json['durationMs'] as int : null,
      explicit: json['explicit'] is bool ? json['explicit'] as bool : null,
    );
  }
}

@immutable
class PlaylistTrack {
  const PlaylistTrack({
    required this.musicId,
    required this.name,
    required this.singer,
    required this.albumName,
    required this.sourceCode,
    required this.qualityCode,
    this.localPath,
    this.picUrl,
    this.musicJson,
    this.spotify,
    this.spotifyMatchIsManual = false,
    this.playlistEntryKey,
  });

  final String musicId;
  final String name;
  final String singer;
  final String albumName;
  final String sourceCode;
  final String qualityCode;
  final String? localPath;
  final String? picUrl;
  final Map<String, dynamic>? musicJson;

  final SpotifyTrackMetadata? spotify;
  final bool spotifyMatchIsManual;
  final String? playlistEntryKey;
  bool get isUnmatchedSpotify => spotify != null && musicInfo == null;
  String get sourceLabel => isUnmatchedSpotify ? '未匹配音源' : source.label;

  MusicSource get source => MusicSource.fromCode(sourceCode);

  String get id => identityKey;

  bool get isLocal => localPath?.trim().isNotEmpty ?? false;

  MusicInfo? get musicInfo {
    final json = musicJson;
    if (json == null) return null;
    try {
      final music = MusicInfo.fromJson(json);
      if (spotify != null &&
          (music.id != musicId ||
              music.id.trim().isEmpty ||
              music.source == MusicSource.all ||
              music.source != source)) {
        return null;
      }
      return music;
    } catch (_) {
      return null;
    }
  }

  String get identityKey => playlistEntryKey ?? canonicalIdentityKey;

  String get canonicalIdentityKey {
    final origin = spotify;
    if (origin != null) return 'spotify:${origin.uri}:${origin.occurrence}';
    final providerKey = providerIdentityKey;
    if (providerKey != null) return providerKey;

    final fileKey = localFileIdentityKey;
    if (fileKey != null) return fileKey;

    return 'fallback:${sourceCode.trim().toLowerCase()}:${musicId.trim()}:'
        '${name.trim().toLowerCase()}:${singer.trim().toLowerCase()}';
  }

  String? get localFileIdentityKey {
    final path = localPath?.trim();
    return path == null || path.isEmpty
        ? null
        : 'file:${normalizePlaylistPath(path)}';
  }

  String? get providerIdentityKey {
    final normalizedSource = sourceCode.trim().toLowerCase();
    final normalizedMusicId = musicId.trim();
    if (normalizedMusicId.isEmpty ||
        normalizedSource.isEmpty ||
        normalizedSource == MusicSource.all.code ||
        isUnmatchedSpotify) {
      return null;
    }
    return 'music:$normalizedSource:$normalizedMusicId';
  }

  factory PlaylistTrack.fromDownloadHistory(DownloadHistoryEntry entry) {
    return PlaylistTrack(
      musicId: entry.musicId,
      name: entry.name,
      singer: entry.singer,
      albumName: entry.albumName,
      sourceCode: entry.sourceCode,
      qualityCode: entry.qualityCode,
      localPath: _nonEmpty(entry.savedPath),
      picUrl: _nonEmpty(entry.picUrl),
      musicJson: entry.musicJson == null
          ? null
          : Map<String, dynamic>.from(entry.musicJson!),
    );
  }

  factory PlaylistTrack.fromMusicInfo(MusicInfo music) {
    return PlaylistTrack(
      musicId: music.id,
      name: music.name,
      singer: music.singer,
      albumName: music.albumName,
      sourceCode: music.source.code,
      qualityCode: music.bestQuality.code,
      picUrl: _nonEmpty(music.meta.picUrl),
      musicJson: Map<String, dynamic>.from(music.toJson()),
    );
  }

  factory PlaylistTrack.fromSpotify(
    SpotifyTrackMetadata original,
    MusicInfo? match, {
    bool manual = false,
  }) {
    return PlaylistTrack(
      musicId: match?.id ?? original.uri,
      name: original.title,
      singer: original.artist,
      albumName: match?.albumName ?? '',
      sourceCode: match?.source.code ?? 'spotify',
      qualityCode: (match?.bestQuality ?? Quality.k128).code,
      picUrl: _nonEmpty(match?.meta.picUrl),
      musicJson: match?.toJson(),
      spotify: original,
      spotifyMatchIsManual: match != null && manual,
    );
  }

  PlaylistTrack withSpotifyMatch(MusicInfo music) => mergePreferLocal(
    PlaylistTrack.fromSpotify(
      spotify!,
      music,
      manual: true,
    ).copyWith(playlistEntryKey: playlistEntryKey),
  );

  PlaylistTrack? spotifyMatchReplacement({
    required PlaylistTrack snapshot,
    required PlaylistTrack replacement,
  }) {
    final original = spotify;
    final proposed = replacement.musicInfo;
    if (original == null || proposed == null) return null;
    final metadata = original.toJson();
    if (!mapEquals(metadata, snapshot.spotify?.toJson()) ||
        !mapEquals(metadata, replacement.spotify?.toJson())) {
      return null;
    }
    if (!replacement.spotifyMatchIsManual) {
      if (!isUnmatchedSpotify || !snapshot.isUnmatchedSpotify) return null;
      return mergePreferLocal(replacement);
    }
    // An automatic match can finish while the picker is open. A newer manual
    // choice, however, must survive an older picker or preview being saved.
    if (spotifyMatchIsManual &&
        (!hasSameSpotifyMatch(snapshot) || hasSameSpotifyMatch(replacement))) {
      return null;
    }
    return withSpotifyMatch(proposed);
  }

  bool hasSameSpotifyMatch(PlaylistTrack other) =>
      spotifyMatchIsManual == other.spotifyMatchIsManual &&
      sourceCode == other.sourceCode &&
      musicId == other.musicId;

  PlaylistTrack copyWith({
    String? musicId,
    String? name,
    String? singer,
    String? albumName,
    String? sourceCode,
    String? qualityCode,
    String? localPath,
    String? picUrl,
    Map<String, dynamic>? musicJson,
    SpotifyTrackMetadata? spotify,
    String? playlistEntryKey,
  }) {
    final entryKey = playlistEntryKey ?? this.playlistEntryKey;
    return PlaylistTrack(
      musicId: musicId ?? this.musicId,
      name: name ?? this.name,
      singer: singer ?? this.singer,
      albumName: albumName ?? this.albumName,
      sourceCode: sourceCode ?? this.sourceCode,
      qualityCode: qualityCode ?? this.qualityCode,
      localPath: localPath ?? this.localPath,
      picUrl: picUrl ?? this.picUrl,
      musicJson: musicJson ?? this.musicJson,
      spotify: spotify ?? this.spotify,
      spotifyMatchIsManual: spotifyMatchIsManual,
      playlistEntryKey: entryKey == canonicalIdentityKey ? null : entryKey,
    );
  }

  PlaylistTrack mergePreferLocal(PlaylistTrack incoming) {
    if (spotify != null && incoming.spotify != null) {
      if (!isUnmatchedSpotify &&
          (incoming.isUnmatchedSpotify ||
              (spotifyMatchIsManual && !incoming.spotifyMatchIsManual))) {
        return copyWith(
          name: incoming.name,
          singer: incoming.singer,
          spotify: incoming.spotify,
        );
      }
      if (musicId != incoming.musicId || sourceCode != incoming.sourceCode) {
        return incoming;
      }
      return incoming.copyWith(
        localPath: incoming.localPath ?? localPath,
        picUrl: incoming.picUrl ?? picUrl,
        qualityCode: !incoming.isLocal && isLocal ? qualityCode : null,
      );
    }
    if (incoming.isLocal || !isLocal) return incoming;
    return incoming.copyWith(localPath: localPath);
  }

  PlaylistTrack withoutLocalPath() {
    return PlaylistTrack(
      musicId: musicId,
      name: name,
      singer: singer,
      albumName: albumName,
      sourceCode: sourceCode,
      qualityCode: qualityCode,
      picUrl: picUrl,
      spotify: spotify,
      spotifyMatchIsManual: spotifyMatchIsManual,
      playlistEntryKey: playlistEntryKey,
      musicJson: musicJson == null
          ? null
          : Map<String, dynamic>.from(musicJson!),
    );
  }

  DownloadHistoryEntry? toDownloadHistoryEntry({required String playlistId}) {
    final path = localPath?.trim();
    if (path == null || path.isEmpty) return null;
    return DownloadHistoryEntry(
      id: 'playlist:$playlistId:$identityKey',
      musicId: musicId,
      name: name,
      singer: singer,
      albumName: albumName,
      sourceCode: sourceCode,
      qualityCode: qualityCode,
      status: DownloadHistoryStatus.completed,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      savedPath: path,
      picUrl: picUrl,
      musicJson: musicJson == null
          ? null
          : Map<String, dynamic>.from(musicJson!),
    );
  }

  DownloadHistoryEntry? toQueueEntry({
    required String playlistId,
    String? downloadedPath,
  }) {
    final path = (downloadedPath ?? localPath)?.trim();
    final savedPath = path != null && path.isNotEmpty && File(path).existsSync()
        ? path
        : null;
    if (savedPath == null && musicInfo == null) return null;
    return DownloadHistoryEntry(
      id: 'playlist:$playlistId:$identityKey',
      musicId: musicId,
      name: name,
      singer: singer,
      albumName: albumName,
      sourceCode: sourceCode,
      qualityCode: qualityCode,
      status: DownloadHistoryStatus.completed,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      savedPath: savedPath,
      preservePlaylistPosition: spotify != null,
      picUrl: picUrl,
      musicJson: musicJson == null
          ? null
          : Map<String, dynamic>.from(musicJson!),
    );
  }

  Map<String, dynamic> toJson() => {
    'musicId': musicId,
    'name': name,
    'singer': singer,
    'albumName': albumName,
    'source': sourceCode,
    'quality': qualityCode,
    if (localPath != null) 'localPath': localPath,
    if (picUrl != null) 'picUrl': picUrl,
    if (musicJson != null) 'musicInfo': musicJson,
    if (spotify != null) 'spotify': spotify!.toJson(),
    if (spotifyMatchIsManual) 'spotifyMatchIsManual': true,
    if (playlistEntryKey != null) 'playlistEntryKey': playlistEntryKey,
  };

  static PlaylistTrack? tryFromJson(Object? value) {
    final json = _mapOrNull(value);
    if (json == null) return null;

    final spotify = SpotifyTrackMetadata.tryFromJson(json['spotify']);
    final track = PlaylistTrack(
      musicId: _string(json['musicId'] ?? json['id']),
      name: _string(json['name']),
      singer: _string(json['singer']),
      albumName: _string(json['albumName'] ?? json['album']),
      sourceCode: _string(json['source'], fallback: MusicSource.all.code),
      qualityCode: _string(json['quality'], fallback: Quality.k128.code),
      localPath: _nonEmpty(_stringOrNull(json['localPath'] ?? json['path'])),
      picUrl: _nonEmpty(_stringOrNull(json['picUrl'])),
      musicJson: _mapOrNull(json['musicInfo']),
      spotify: spotify,
      spotifyMatchIsManual: json['spotifyMatchIsManual'] == true,
      playlistEntryKey: spotify == null
          ? null
          : _nonEmpty(_stringOrNull(json['playlistEntryKey'])),
    );

    if (track.name.trim().isEmpty && !track.isLocal) return null;
    if (track.identityKey.startsWith('fallback:') &&
        track.musicId.trim().isEmpty &&
        track.name.trim().isEmpty) {
      return null;
    }
    return track;
  }
}

@immutable
class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    required this.tracks,
    required this.createdAt,
    required this.updatedAt,
    this.originPlaylistId,
    this.originSourceCode,
    this.onlineTrackIds,
    this.movedOutTrackIds,
    this.movedOutTrackProviders,
    this.customTrackOrder,
    this.originTrackCount,
    this.originPreviewCount,
    this.coverUrl,
    this.creator,
    this.description,
  });

  final String id;
  final String name;
  final List<PlaylistTrack> tracks;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? originPlaylistId;
  final String? originSourceCode;
  final List<String>? onlineTrackIds;
  final List<String>? movedOutTrackIds;
  final Map<String, String?>? movedOutTrackProviders;
  final List<String>? customTrackOrder;
  final int? originTrackCount;
  final int? originPreviewCount;
  final String? coverUrl;
  final String? creator;
  final String? description;

  List<PlaylistTrack> get customOrderedTracks {
    final order = _customOrderForTracks(customTrackOrder, tracks);
    if (order == null) return List<PlaylistTrack>.unmodifiable(tracks);
    final byId = {for (final track in tracks) track.identityKey: track};
    return List<PlaylistTrack>.unmodifiable([
      for (final id in order) byId[id]!,
    ]);
  }

  String? get onlinePlaylistId {
    final value = originPlaylistId?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  MusicSource? get onlineSource {
    final code = originSourceCode?.trim();
    if (code == null || code.isEmpty) return null;
    final source = MusicSource.tryFromCode(code);
    return source == null || source == MusicSource.all ? null : source;
  }

  bool get isOnlineImport => onlinePlaylistId != null && onlineSource != null;

  LocalPlaylist copyWith({
    String? name,
    List<PlaylistTrack>? tracks,
    DateTime? updatedAt,
    List<String>? onlineTrackIds,
    List<String>? movedOutTrackIds,
    Map<String, String?>? movedOutTrackProviders,
    List<String>? customTrackOrder,
  }) {
    return LocalPlaylist(
      id: id,
      name: name ?? this.name,
      tracks: tracks ?? this.tracks,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      originPlaylistId: originPlaylistId,
      originSourceCode: originSourceCode,
      onlineTrackIds: onlineTrackIds ?? this.onlineTrackIds,
      movedOutTrackIds: movedOutTrackIds == null
          ? this.movedOutTrackIds
          : List<String>.unmodifiable(movedOutTrackIds),
      movedOutTrackProviders: movedOutTrackProviders == null
          ? this.movedOutTrackProviders
          : Map<String, String?>.unmodifiable(movedOutTrackProviders),
      customTrackOrder: _customOrderForTracks(
        customTrackOrder ?? this.customTrackOrder,
        tracks ?? this.tracks,
      ),
      originTrackCount: originTrackCount,
      originPreviewCount: originPreviewCount,
      coverUrl: coverUrl,
      creator: creator,
      description: description,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'tracks': [for (final track in tracks) track.toJson()],
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (originPlaylistId != null) 'originPlaylistId': originPlaylistId,
    if (originSourceCode != null) 'originSource': originSourceCode,
    if (onlineTrackIds != null) 'onlineTrackIds': onlineTrackIds,
    if (movedOutTrackIds != null) 'movedOutTrackIds': movedOutTrackIds,
    if (movedOutTrackProviders?.isNotEmpty ?? false)
      'movedOutTrackProviders': movedOutTrackProviders,
    if (customTrackOrder != null) 'customTrackOrder': customTrackOrder,
    if (originTrackCount != null) 'originTrackCount': originTrackCount,
    if (originPreviewCount != null) 'originPreviewCount': originPreviewCount,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (creator != null) 'creator': creator,
    if (description != null) 'description': description,
  };

  static LocalPlaylist? tryFromJson(Object? value) {
    final json = _mapOrNull(value);
    if (json == null) return null;

    final id = _string(json['id']).trim();
    final name = _string(json['name']).trim();
    if (id.isEmpty || name.isEmpty) return null;

    final tracks = <PlaylistTrack>[];
    final seen = <String>{};
    final rawTracks = json['tracks'];
    if (rawTracks is List) {
      for (final rawTrack in rawTracks) {
        final track = PlaylistTrack.tryFromJson(rawTrack);
        if (track != null && seen.add(track.identityKey)) tracks.add(track);
      }
    }

    final createdAt = _dateTime(json['createdAt']);
    final updatedAt = _dateTime(json['updatedAt']) ?? createdAt;
    final movedOutProviders = _mapOrNull(json['movedOutTrackProviders']);
    return LocalPlaylist(
      id: id,
      name: name,
      tracks: List<PlaylistTrack>.unmodifiable(tracks),
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      originPlaylistId: _nonEmpty(_stringOrNull(json['originPlaylistId'])),
      originSourceCode: _nonEmpty(
        _stringOrNull(json['originSource'] ?? json['originSourceCode']),
      ),
      onlineTrackIds: _stringListOrNull(json['onlineTrackIds']),
      movedOutTrackIds: _stringListOrNull(json['movedOutTrackIds']),
      movedOutTrackProviders: movedOutProviders == null
          ? null
          : Map<String, String?>.unmodifiable({
              for (final entry in movedOutProviders.entries)
                if (entry.value == null || entry.value is String)
                  entry.key: entry.value as String?,
            }),
      customTrackOrder: _customOrderForTracks(
        _stringListOrNull(json['customTrackOrder']),
        tracks,
      ),
      originPreviewCount: json['originPreviewCount'] is int
          ? json['originPreviewCount'] as int
          : null,
      originTrackCount: json['originTrackCount'] is int
          ? json['originTrackCount'] as int
          : null,
      coverUrl: _nonEmpty(_stringOrNull(json['coverUrl'])),
      creator: _nonEmpty(_stringOrNull(json['creator'])),
      description: _nonEmpty(_stringOrNull(json['description'])),
    );
  }
}

// Keep the overlay complete on every track mutation, without changing tracks.
List<String>? _customOrderForTracks(
  List<String>? order,
  List<PlaylistTrack> tracks,
) {
  if (order == null) return null;
  final ids = {for (final track in tracks) track.identityKey};
  final seen = <String>{};
  return List<String>.unmodifiable([
    for (final id in order)
      if (ids.contains(id) && seen.add(id)) id,
    for (final track in tracks)
      if (seen.add(track.identityKey)) track.identityKey,
  ]);
}

String normalizePlaylistPath(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

Map<String, dynamic>? _mapOrNull(Object? value) {
  if (value is Map<String, dynamic>) return Map<String, dynamic>.from(value);
  if (value is Map) {
    try {
      return Map<String, dynamic>.from(value);
    } catch (_) {
      return null;
    }
  }
  return null;
}

String _string(Object? value, {String fallback = ''}) {
  return value is String ? value : fallback;
}

String? _stringOrNull(Object? value) => value is String ? value : null;

List<String>? _stringListOrNull(Object? value) {
  if (value is! List) return null;
  final values = <String>[];
  final seen = <String>{};
  for (final item in value) {
    if (item is! String) continue;
    final normalized = item.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) values.add(normalized);
  }
  return List<String>.unmodifiable(values);
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

DateTime? _dateTime(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value);
}
