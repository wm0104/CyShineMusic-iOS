import 'package:flutter_test/flutter_test.dart';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/artist_info.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/features/player/player_artist_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('known multi-artist identities are kept separate without a combined search', () async {
    final api = _Api();
    final result = await resolvePlayerArtists(_request('A、B'), api: api,
      readCredits: (_) async => [_artist('a', 'A'), _artist('b', 'B')]);
    expect(result.artists.map((a) => a.id), ['a', 'b']);
    expect(result.unresolvedNames, isEmpty);
    expect(result.singleArtist, isNull);
    expect(api.queries, isEmpty);
  });
  test('only missing credits are searched individually on the current platform', () async {
    final api = _Api()..results['B'] = [_artist('b', 'B')];
    final music = _music('A、B', metadata: [
      {'id': 'a', 'name': 'A'},
    ]);
    final result = await resolvePlayerArtists(_request('A、B', music: music), api: api,
      readCredits: (_) async => [_artist('a', 'A')]);
    expect(api.queries, ['B']);
    expect(result.artists.map((a) => a.id), ['a', 'b']);
    expect(result.singleArtist, isNull);
  });
  test('legacy multi-artist names are never sent as one keyword', () async {
    final api = _Api()..results['A'] = [_artist('a', 'A')]
        ..results['B'] = [_artist('b', 'B')];
    final result = await resolvePlayerArtists(_request('A、 B'), api: api,
      readCredits: (_) async => []);
    expect(api.queries, ['A', 'B']);
    expect(result.artists.map((a) => a.name), ['A', 'B']);
  });
  test('homonyms and fuzzy results require manual selection rather than first match', () async {
    final api = _Api()..results['A'] = [_artist('a1', 'A'), _artist('a2', 'A')];
    final ambiguous = await resolvePlayerArtists(_request('A'), api: api,
      readCredits: (_) async => []);
    expect(ambiguous.singleArtist, isNull);
    expect(ambiguous.unresolvedNames, ['A']);
    api.results['A'] = [_artist('other', 'Another Artist')];
    final fuzzy = await resolvePlayerArtists(_request('A'), api: api,
      readCredits: (_) async => []);
    expect(fuzzy.artists, isEmpty);
    expect(fuzzy.unresolvedNames, ['A']);
  });
  test('a unique exact same-source identity can open directly', () async {
    final api = _Api()..results['A'] = [_artist('a', 'A')];
    final result = await resolvePlayerArtists(_request('A'), api: api,
      readCredits: (_) async => []);
    expect(result.singleArtist!.id, 'a');
    expect(result.singleArtist!.source, MusicSource.wy);
  });
  test('unsupported and bare local files never silently resolve on another platform', () async {
    final api = _Api();
    var reads = 0;
    final unsupported = await resolvePlayerArtists(_request('A', music: _music('A', source: 'kg')),
      api: api, readCredits: (_) async { reads++; return [_artist('a', 'A')]; });
    expect(unsupported.unresolvedNames, ['A']);
    final local = await resolvePlayerArtists(const PlayerArtistRequest(
      trackId: 'local', title: 'File', artist: 'A'), api: api);
    expect(local.unresolvedNames, ['A']);
    expect(reads, 0);
    expect(api.queries, isEmpty);
  });
  test('metadata identity with a separator in its real name is not split', () async {
    final result = await resolvePlayerArtists(_request('A、B'), api: _Api(),
      readCredits: (_) async => [_artist('band', 'A、B')]);
    expect(result.singleArtist!.id, 'band');
    expect(result.unresolvedNames, isEmpty);
  });
  for (final source in MusicApi.artistSources) {
    test('${source.code}: same-source IDs win and foreign credits never redirect', () async {
      final api = _Api(expectedSource: source);
      final own = ArtistInfo(id: 'own', name: 'A', source: source);
      final foreignSource = source == MusicSource.wy ? MusicSource.tx : MusicSource.wy;
      final result = await resolvePlayerArtists(
        _request('A', music: _music('A', source: source.code)), api: api,
        readCredits: (_) async => [
          ArtistInfo(id: 'foreign', name: 'A', source: foreignSource), own,
        ]);
      expect(result.singleArtist, same(own));
      expect(api.queries, isEmpty);
      api.results['A'] = [
        ArtistInfo(id: 'foreign', name: 'A', source: foreignSource), own,
      ];
      final fallback = await resolvePlayerArtists(
        _request('A', music: _music('A', source: source.code)), api: api,
        readCredits: (_) async => []);
      expect(fallback.singleArtist, same(own));
      expect(api.queries, ['A']);
      api.results['A'] = [own, ArtistInfo(id: 'other', name: 'A', source: source)];
      final ambiguous = await resolvePlayerArtists(
        _request('A', music: _music('A', source: source.code)), api: api,
        readCredits: (_) async => []);
      expect(ambiguous.singleArtist, isNull);
      expect(ambiguous.unresolvedNames, ['A']);
    });
  }
  test('partial structured credits preserve a real separator name and the missing person', () async {
    final api = _Api()..results['A、B'] = [_artist('band', 'A、B')];
    final result = await resolvePlayerArtists(_request('A、B、C', music:
      _music('A、B、C', metadata: [{'name': 'A、B'}, {'name': 'C'}])), api: api,
      readCredits: (_) async => []);
    expect(api.queries, ['A、B', 'C']);
    expect(result.artists.single.id, 'band');
    expect(result.unresolvedNames, ['C']);
    expect(result.singleArtist, isNull);
  });
  test('a single structured real name is not split when its ID is absent', () async {
    final api = _Api()..results['A、B'] = [_artist('band', 'A、B')];
    final result = await resolvePlayerArtists(_request('A、B', music:
      _music('A、B', metadata: [{'name': 'A、B'}])), api: api,
      readCredits: (_) async => []);
    expect(api.queries, ['A、B']);
    expect(result.singleArtist!.id, 'band');
  });
  test('metadata failure still resolves individual names without losing partial credits', () async {
    final api = _Api()..results['A'] = [_artist('a', 'A')];
    final result = await resolvePlayerArtists(_request('A、B'), api: api,
      readCredits: (_) async => throw StateError('offline'));
    expect(result.artists.single.id, 'a');
    expect(result.unresolvedNames, ['B']);
    expect(result.singleArtist, isNull);
    expect(api.queries, ['A', 'B']);
  });
  test('unknown artist values do not produce fake identities', () async {
    final api = _Api();
    final result = await resolvePlayerArtists(const PlayerArtistRequest(
      trackId: 'unknown', title: 'File', artist: '未知歌手'), api: api);
    expect(result.artists, isEmpty);
    expect(result.unresolvedNames, isEmpty);
    expect(api.queries, isEmpty);
    expect(hasPlayerArtistName('未知歌手'), isFalse);
    expect(playerArtistNames('Earth, Wind & Fire'), ['Earth, Wind & Fire']);
  });
}

PlayerArtistRequest _request(String artist, {MusicInfo? music}) => PlayerArtistRequest(
  trackId: 'song', title: 'Song', artist: artist, music: music ?? _music(artist));
ArtistInfo _artist(String id, String name) => ArtistInfo(id: id, name: name, source: MusicSource.wy);
MusicInfo _music(String singer, {String source = 'wy', List<Map<String, dynamic>>? metadata}) => MusicInfo.fromJson({
  'id': 'song', 'name': 'Song', 'singer': singer, 'source': source,
  'meta': {'songId': 'song', 'albumName': 'Album', if (metadata != null) 'artists': metadata},
});
class _Api extends MusicApi {
  _Api({this.expectedSource = MusicSource.wy});
  final MusicSource expectedSource;
  final queries = <String>[];
  final results = <String, List<ArtistInfo>>{};
  @override
  Future<SearchResponse> searchArtists({required String keyword, required MusicSource source,
    int page = 1, int limit = 30}) async {
    expect(source, expectedSource);
    queries.add(keyword);
    final artists = results[keyword] ?? [];
    return SearchResponse(list: const [], artists: artists, page: page, limit: limit,
      allPage: 1, total: artists.length, source: source);
  }
}
