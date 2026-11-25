import 'enums.dart';
import 'music_info.dart';

class PlaylistInfo {
  const PlaylistInfo({
    required this.id,
    required this.name,
    required this.source,
    required this.tracks,
    this.coverUrl,
    this.creator,
    this.description,
    this.playCount,
    this.trackCount,
    bool? hasMoreTracks,
  }) : _hasMoreTracks = hasMoreTracks;

  final String id;
  final String name;
  final MusicSource source;
  final List<MusicInfo> tracks;
  final String? coverUrl;
  final String? creator;
  final String? description;
  final int? playCount;
  final int? trackCount;
  final bool? _hasMoreTracks;

  int get totalTracks => trackCount ?? tracks.length;
  bool get hasMoreTracks => _hasMoreTracks ?? tracks.length < totalTracks;
}

class ParsedPlaylistTarget {
  const ParsedPlaylistTarget({required this.id, required this.source});

  final String id;
  final MusicSource source;
}
