import '../models/artist_info.dart';
import '../models/enums.dart';
import '../models/search_response.dart';
import '../ui/cover_image_source.dart';
import 'internal/sdk_http.dart';
import 'playlist_sdk.dart';

class WyArtistSdk {
  const WyArtistSdk._();

  static Future<SearchResponse> search({
    required String keyword,
    required int page,
    required int limit,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    final uri = Uri.https('music.163.com', '/api/search/get', {
      's': keyword,
      'type': '100',
      'offset': '${(page - 1) * limit}',
      'limit': '$limit',
    });
    final body = await loadJson(uri.toString());
    if (body is! Map || body['code'] != 200 || body['result'] is! Map) {
      throw Exception('网易云歌手搜索失败');
    }
    final result = body['result'] as Map;
    final artists = <ArtistInfo>[];
    for (final item
        in (result['artists'] as List? ?? const []).whereType<Map>()) {
      final id = item['id']?.toString() ?? '';
      final name = item['name']?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty) continue;
      artists.add(
        ArtistInfo(
          id: id,
          name: name,
          source: MusicSource.wy,
          coverUrl: CoverImageSource.normalizeUrl(
            (item['img1v1Url'] ?? item['picUrl'])?.toString(),
          ),
        ),
      );
    }
    final total = (result['artistCount'] as num?)?.toInt() ?? artists.length;
    return SearchResponse(
      list: const [],
      artists: artists,
      total: total,
      page: page,
      limit: limit,
      allPage: (total / limit).ceil(),
      source: MusicSource.wy,
    );
  }

  static Future<ArtistTrackPage> songs({
    required String artistId,
    required int offset,
    required int limit,
    SdkJsonLoader loadJson = SdkHttp.getJson,
  }) async {
    final uri = Uri.https('music.163.com', '/api/v1/artist/songs', {
      'id': artistId,
      'order': 'hot',
      'offset': '$offset',
      'limit': '$limit',
    });
    final body = await loadJson(uri.toString());
    if (body is! Map || body['code'] != 200 || body['songs'] is! List) {
      throw Exception('网易云歌手歌曲加载失败');
    }
    final rows = (body['songs'] as List).whereType<Map>();
    final artist = rows
        .expand(
          (song) => (song['artists'] as List? ?? const []).whereType<Map>(),
        )
        .where((item) => item['id']?.toString() == artistId)
        .firstOrNull;
    final tracks = [for (final row in rows) ?PlaylistSdk.parseWySong(row)];
    return ArtistTrackPage(
      tracks: tracks,
      offset: offset,
      total: (body['total'] as num?)?.toInt() ?? offset + tracks.length,
      artistName: artist?['name']?.toString(),
      coverUrl: CoverImageSource.normalizeUrl(artist?['picUrl']?.toString()),
    );
  }
}
