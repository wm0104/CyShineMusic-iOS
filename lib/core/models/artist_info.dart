import 'enums.dart';
import 'music_info.dart';

class ArtistInfo {
  const ArtistInfo({
    required this.id,
    required this.name,
    required this.source,
    this.coverUrl,
  });

  final String id;
  final String name;
  final MusicSource source;
  final String? coverUrl;
}

class ArtistTrackPage {
  const ArtistTrackPage({
    required this.tracks,
    required this.total,
    required this.offset,
    this.artistName,
    this.coverUrl,
  });

  final List<MusicInfo> tracks;
  final int total;
  final int offset;
  final String? artistName;
  final String? coverUrl;
}
