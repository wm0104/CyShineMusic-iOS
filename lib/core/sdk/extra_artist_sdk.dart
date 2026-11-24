import 'dart:convert';

import '../models/artist_info.dart';
import '../models/enums.dart';
import '../models/search_response.dart';
import '../ui/cover_image_source.dart';
import 'internal/format.dart';
import 'internal/sdk_http.dart';
import 'leaderboard_sdk.dart';
import 'playlist_adapters/kw_playlist_adapter.dart';

class ExtraArtistSdk {
  static const sources = {MusicSource.kw, MusicSource.tx};

  static Future<SearchResponse> search({
    required String keyword,
    required MusicSource source,
    required int page,
    required int limit,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    final qq = source == MusicSource.tx;
    if (!sources.contains(source)) throw ArgumentError.value(source);
    final uri = qq
        ? Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
            't': '9',
            'format': 'json',
            'w': keyword,
            'p': '$page',
            'n': '$limit',
          })
        : Uri.https('wapi.kuwo.cn', '/api/www/search/searchArtistBykeyWord', {
            'key': keyword,
            'pn': '$page',
            'rn': '$limit',
          });
    final body = await loadJson(uri.toString());
    final result = body is Map && body['code'] == (qq ? 0 : 200)
        ? body['data']
        : null;
    final data = result is Map && qq ? result['singer'] : result;
    if (data is! Map || data['list'] is! List) {
      throw FormatException('${source.label}歌手搜索失败');
    }
    final artists = <ArtistInfo>[];
    for (final row in (data['list'] as List).whereType<Map>()) {
      final id = row[qq ? 'singerMID' : 'id']?.toString() ?? '';
      final name = decodeName(row[qq ? 'singerName' : 'name']).trim();
      if (id.isEmpty || name.isEmpty) continue;
      artists.add(
        ArtistInfo(
          id: id,
          name: name,
          source: source,
          coverUrl: CoverImageSource.normalizeUrl(
            row[qq ? 'singerPic' : 'pic']?.toString(),
          ),
        ),
      );
    }
    final total =
        int.tryParse(data[qq ? 'totalnum' : 'total'].toString()) ??
        artists.length;
    return SearchResponse(
      list: const [],
      artists: artists,
      page: page,
      limit: limit,
      total: total,
      allPage: (total / limit).ceil(),
      source: source,
    );
  }

  static Future<ArtistTrackPage> songs({
    required String artistId,
    required MusicSource source,
    required int offset,
    required int limit,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    if (!sources.contains(source)) throw ArgumentError.value(source);
    if (source == MusicSource.kw) {
      final uri = Uri.https('search.kuwo.cn', '/r.s', {
        'stype': 'artist2music',
        'artistid': artistId,
        'order': 'hot',
        'pn': '${offset ~/ limit}',
        'rn': '$limit',
        'rformat': 'json',
        'encoding': 'utf8',
        'pcjson': '1',
      });
      final body = await loadJson(uri.toString());
      if (body is! Map || body['musiclist'] is! List) {
        throw const FormatException('酷我歌手歌曲加载失败');
      }
      final rows = (body['musiclist'] as List)
          .skip(offset % limit)
          .whereType<Map>();
      return ArtistTrackPage(
        artistName: decodeName(body['artist']),
        offset: offset,
        total: int.parse(body['total'].toString()),
        tracks: [
          for (final row in rows)
            ?KwPlaylistAdapter.parseTrack({
              ...row,
              'id': row['musicrid'],
              'artist': decodeName(row['artist']).replaceAll('&', '、'),
            }),
        ],
      );
    }

    final uri = Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg', {
      'format': 'json',
      'data': jsonEncode({
        'singer': {
          'module': 'musichall.song_list_server',
          'method': 'GetSingerSongList',
          'param': {
            'singerMid': artistId,
            'begin': offset,
            'num': limit,
            'order': 1,
          },
        },
      }),
    });
    final body = await loadJson(uri.toString());
    final reply = body is Map && body['code'] == 0 ? body['singer'] : null;
    final data = reply is Map && reply['code'] == 0 ? reply['data'] : null;
    if (data is! Map || data['songList'] is! List) {
      throw const FormatException('QQ 歌手歌曲加载失败');
    }
    final rows = (data['songList'] as List)
        .whereType<Map>()
        .map((row) => row['songInfo'])
        .whereType<Map>();
    final artist = rows
        .expand((row) => (row['singer'] as List? ?? const []).whereType<Map>())
        .where((singer) => singer['mid'] == artistId)
        .firstOrNull;
    return ArtistTrackPage(
      tracks: [for (final row in rows) ?LeaderboardSdk.parseTxTrack(row)],
      offset: offset,
      total: int.parse(data['totalNum'].toString()),
      artistName: artist?['name']?.toString(),
      coverUrl:
          'https://y.gtimg.cn/music/photo_new/T001R300x300M000$artistId.jpg',
    );
  }
}
