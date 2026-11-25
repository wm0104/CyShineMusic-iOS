import 'package:test/test.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/sdk/track_artist_sdk.dart';

MusicInfo track(MusicSource source, [Map<String, dynamic> meta = const {}]) =>
    MusicInfo.fromJson({
      'id': '${source.code}_song', 'name': 'Song', 'singer': 'A、B',
      'source': source.code, 'meta': {'songId': 'song', ...meta},
    });

void main() {
  test('structured credits remain separate and need independent IDs', () {
    final artists = TrackArtistSdk.fromMetadata(track(MusicSource.wy, {
      'artists': [
        {'id': 12, 'name': 'A', 'picUrl': 'http://p1.music.126.net/a.jpg'},
        {'id': '13', 'name': 'B'},
        {'name': 'Missing ID'}, {'id': 0, 'name': 'Unknown'}, null,
      ],
    }));
    expect(artists.map((a) => a.id), ['12', '13']);
    expect(artists.map((a) => a.name), ['A', 'B']);
    expect(artists.first.coverUrl, 'https://p1.music.126.net/a.jpg');
    expect(artists.every((a) => a.source == MusicSource.wy), isTrue);
  });

  test('distinct artist IDs with the same display name are not merged', () {
    final result = TrackArtistSdk.fromMetadata(track(MusicSource.wy, {
      'artists': [{'id': '12', 'name': 'Same'}, {'id': '13', 'name': 'Same'}],
    }));
    expect(result.map((a) => a.id), ['12', '13']);
  });

  test('unsupported source never loads and does not invent song-ID identity', () async {
    var calls = 0;
    final result = await TrackArtistSdk.read(track(MusicSource.kg, {
      'artists': [{'id': '12', 'name': 'A'}],
    }), loadJson: (url, {headers}) async { calls++; return {}; });
    expect(result, isEmpty);
    expect(calls, 0);
    expect(TrackArtistSdk.fromMetadata(track(MusicSource.wy)), isEmpty);
  });

  test('metadata hit needs no request', () async {
    final result = await TrackArtistSdk.read(track(MusicSource.tx, {
      'singer': [{'id': 999, 'mid': 'singer-mid', 'name': 'A'}],
    }), loadJson: (url, {headers}) async => throw StateError('unexpected HTTP'));
    expect(result.single.id, 'singer-mid');
  });

  test('WY detail is same-song, same-source and has no Cookie', () async {
    final result = await TrackArtistSdk.read(track(MusicSource.wy),
      loadJson: (url, {headers}) async {
        final uri = Uri.parse(url);
        expect(uri.host, 'music.163.com');
        expect(uri.queryParameters['ids'], '["song"]');
        expect(headers?.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
        return {'code': 200, 'songs': [
          {'id': 'other', 'artists': [{'id': 99, 'name': 'Wrong'}]},
          {'id': 'song', 'artists': [{'id': 12, 'name': 'A'}, {'id': 13, 'name': 'B'}]},
        ]};
      });
    expect(result.map((a) => a.id), ['12', '13']);
  });

  test('wrong song and malformed lists cannot create identities', () async {
    for (final songs in [null, {}, [null, 'bad'], [
      {'id': 'other', 'artists': [{'id': 12, 'name': 'A'}]},
    ], [
      {'id': 'song', 'artists': [null, {}, {'name': 'A'}]},
    ]]) {
      expect(await TrackArtistSdk.read(track(MusicSource.wy),
        loadJson: (url, {headers}) async => {'code': 200, 'songs': songs}), isEmpty);
    }
  });

  test('QQ detail uses singer mid, never numeric song or singer IDs', () async {
    final result = await TrackArtistSdk.read(track(MusicSource.tx),
      loadJson: (url, {headers}) async => {'code': 0, 'detail': {'code': 0, 'data': {
        'track_info': {'mid': 'song', 'id': 123, 'singer': [
          {'mid': 'artist-mid', 'id': 456, 'name': 'A'},
          {'id': 789, 'name': 'No mid'},
        ]},
      }}});
    expect(result.single.id, 'artist-mid');
  });

  test('KW single artist ID accepted; combined display name is not split', () async {
    Future<List<String>> read(String name) async => (await TrackArtistSdk.read(
      track(MusicSource.kw), loadJson: (url, {headers}) async => {
        'data': {'songinfo': {'id': 'song', 'artistId': '336', 'artist': name}},
      })).map((a) => a.id).toList();
    expect(await read('A'), ['336']);
    expect(await read('A&B'), isEmpty);
    expect(await read('A、B'), isEmpty);
  });

  test('HTTP failures remain observable to caller', () async {
    await expectLater(TrackArtistSdk.read(track(MusicSource.wy),
      loadJson: (url, {headers}) async => throw StateError('offline')),
      throwsStateError);
  });
}
