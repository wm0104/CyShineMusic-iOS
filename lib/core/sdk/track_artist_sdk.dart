import 'dart:convert';

import '../models/artist_info.dart';
import '../models/enums.dart';
import '../models/music_info.dart';
import 'internal/builders.dart';
import 'internal/sdk_http.dart';

/// Reads original track credits only. No name search, login or audio resolution.
class TrackArtistSdk {
  TrackArtistSdk._();

  static const _sources = {MusicSource.wy, MusicSource.tx, MusicSource.kw};

  static List<ArtistInfo> fromMetadata(MusicInfo music) {
    if (!_sources.contains(music.source)) return [];
    final meta = music.meta.raw;
    var credits = normalizeArtistCredits(meta['artists']);
    if (credits.isEmpty && music.source == MusicSource.wy) {
      credits = normalizeArtistCredits(meta['ar']);
    }
    if (credits.isEmpty && music.source == MusicSource.tx) {
      credits = normalizeArtistCredits(meta['singer'], idKey: 'mid');
    }
    return _artists(music.source, credits);
  }

  static Future<List<ArtistInfo>> read(
    MusicInfo music, {
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    if (!_sources.contains(music.source)) return [];
    final cached = fromMetadata(music);
    if (cached.isNotEmpty) return cached;
    final id = music.meta.songId.toString().trim();
    if (id.isEmpty || id == '0') return [];

    List<Map<String, dynamic>> credits = [];
    switch (music.source) {
      case MusicSource.wy:
        final body = await loadJson(Uri.https('music.163.com', '/api/song/detail', {
          'ids': jsonEncode([id]),
        }).toString());
        if (body is! Map || body['code'] != 200 || body['songs'] is! List) return [];
        for (final song in (body['songs'] as List).whereType<Map>()) {
          if (song['id']?.toString() != id) continue;
          credits = normalizeArtistCredits(song['ar'] is List ? song['ar'] : song['artists']);
          break;
        }
      case MusicSource.tx:
        final body = await loadJson(Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg', {
          'format': 'json',
          'data': jsonEncode({
            'detail': {
              'module': 'music.pf_song_detail_svr',
              'method': 'get_song_detail_yqq',
              'param': {'song_mid': id},
            },
          }),
        }).toString());
        final detail = body is Map && body['code'] == 0 ? body['detail'] : null;
        final data = detail is Map && detail['code'] == 0 ? detail['data'] : null;
        final song = data is Map ? data['track_info'] : null;
        if (song is! Map || song['mid']?.toString() != id) return [];
        credits = normalizeArtistCredits(song['singer'], idKey: 'mid');
      case MusicSource.kw:
        final body = await loadJson(Uri.https('m.kuwo.cn', '/newh5/singles/songinfoandlrc', {
          'musicId': id,
        }).toString());
        final data = body is Map ? body['data'] : null;
        final song = data is Map ? data['songinfo'] : null;
        if (song is! Map || song['id']?.toString() != id) return [];
        // This legacy response has one ID, not an ID per display-name segment.
        final name = song['artist'];
        if (name is! String || RegExp(r'[&、,，;/]').hasMatch(name)) return [];
        credits = normalizeArtistCredits([
          {'id': song['artistId'], 'name': name},
        ]);
      default:
        return [];
    }
    return _artists(music.source, credits);
  }

  static List<ArtistInfo> _artists(
    MusicSource source,
    List<Map<String, dynamic>> credits,
  ) => [
    for (final row in credits)
      ArtistInfo(
        id: row['id'] as String,
        name: row['name'] as String,
        source: source,
        coverUrl: row['coverUrl'] as String?,
      ),
  ];
}
