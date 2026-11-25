import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/artist_info.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/sdk/track_artist_sdk.dart';
import '../../core/services/app_logger.dart';

class PlayerArtistRequest {
  const PlayerArtistRequest({required this.trackId, required this.title,
    required this.artist, this.music});

  final String trackId;
  final String title;
  final String artist;
  final MusicInfo? music;
}

class PlayerArtistResolution {
  const PlayerArtistResolution({required this.artists, required this.unresolvedNames,
    required this.source});

  final List<ArtistInfo> artists;
  final List<String> unresolvedNames;
  final MusicSource? source;

  ArtistInfo? get singleArtist => artists.length == 1 && unresolvedNames.isEmpty
      ? artists.single : null;
}

class PlayerArtistSelection {
  const PlayerArtistSelection(this.request, this.resolution, {this.returnLocation = '/songs'});
  final String returnLocation;
  final PlayerArtistRequest request;
  final PlayerArtistResolution resolution;
}

final playerArtistSelectionProvider = StateProvider<PlayerArtistSelection?>((ref) => null);

bool hasPlayerArtistName(String value) {
  final name = value.trim().toLowerCase();
  return name.isNotEmpty && name != '未知歌手' && name != 'unknown artist' && name != 'unknown';
}

/// The standardized display separator is a fallback for legacy metadata only.
/// This never changes manual search parsing or splits commas inside artist names.
List<String> playerArtistNames(String value) => value.split('、')
    .map((name) => name.trim()).where(hasPlayerArtistName).toSet().toList(growable: false);

Future<PlayerArtistResolution> resolvePlayerArtists(PlayerArtistRequest request, {
  required MusicApi api,
  Future<List<ArtistInfo>> Function(MusicInfo) readCredits = TrackArtistSdk.read,
}) async {
  final music = request.music;
  final source = music?.source;
  final names = <String>[];
  final metadataArtists = music?.meta.raw['artists'];
  if (metadataArtists is List) {
    for (final item in metadataArtists.whereType<Map>()) {
      final name = item['name'];
      if (name is String && hasPlayerArtistName(name)) names.add(name.trim());
    }
  }
  final resolved = <ArtistInfo>[];
  final unresolved = <String>[];
  final seen = <String>{};
  void add(ArtistInfo artist) {
    if (artist.id.trim().isNotEmpty && hasPlayerArtistName(artist.name) &&
        seen.add('${artist.source.code}:${artist.id}')) resolved.add(artist);
  }
  if (music != null && MusicApi.artistSources.contains(source)) {
    try {
      for (final artist in await readCredits(music)) {
        if (artist.source == source) add(artist);
      }
    } catch (error) {
      await AppLogger.write('player-artist', '读取歌曲歌手失败 source=${source?.code}: $error');
    }
  }
  // Structured credits are identities/names, not display separators. Remove
  // those complete names first so a real name containing 、 stays intact.
  var remaining = request.artist.trim();
  final creditedNames = {...names, ...resolved.map((artist) => artist.name.trim())}
      .toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final name in creditedNames) {
    remaining = remaining.replaceAllMapped(
      RegExp('(^|、)${RegExp.escape(name)}(?=、|\$)', caseSensitive: false),
      (match) => match.group(1)!,
    );
  }
  names.addAll(playerArtistNames(remaining));
  for (final name in names.toSet()) {
    if (resolved.any((artist) => artist.name.trim().toLowerCase() == name.toLowerCase())) continue;
    if (source == null || !MusicApi.artistSources.contains(source)) {
      unresolved.add(name);
      continue;
    }
    try {
      final result = await api.searchArtists(keyword: name, source: source, limit: 30);
      final exact = <String, ArtistInfo>{
        for (final artist in result.artists)
          if (artist.source == source && artist.id.trim().isNotEmpty &&
              artist.name.trim().toLowerCase() == name.toLowerCase()) artist.id: artist,
      };
      if (exact.length == 1) add(exact.values.single);
      else unresolved.add(name);
    } catch (error) {
      unresolved.add(name);
      await AppLogger.write('player-artist', '查找歌手失败 source=${source.code}: $error');
    }
  }
  return PlayerArtistResolution(artists: List.unmodifiable(resolved),
    unresolvedNames: List.unmodifiable(unresolved), source: source);
}
