import 'dart:convert';

import 'package:test/test.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/sdk/internal/builders.dart';
import 'package:cy_shine_music/core/sdk/playlist_sdk.dart';
import 'package:cy_shine_music/core/sdk/track_artist_sdk.dart';

void main() {
  test('builder without additions preserves original raw exactly', () {
    final music = buildMusicInfo(name: 'Song', singer: 'Singer',
      source: MusicSource.tx, songId: 'mid', interval: '03:38',
      qualitys: const [QualityOption(type: Quality.k128, size: '3 MB', mediaInfo: 'media')],
      albumId: 'album', strMediaMid: 'media', metaId: 42, albumMid: 'album');
    expect(music.toJson(), {
      'id': 'tx_mid', 'name': 'Song', 'singer': 'Singer', 'source': 'tx', 'interval': '03:38',
      'meta': {
        'songId': 'mid', 'albumName': '', 'picUrl': '',
        'qualitys': [{'type': '128k', 'size': '3 MB', 'mediaInfo': 'media'}],
        '_qualitys': {'128k': {'size': '3 MB', 'mediaInfo': 'media'}},
        'albumId': 'album', 'strMediaMid': 'media', 'id': 42, 'albumMid': 'album',
      },
    });
  });

  test('exact milliseconds and structured credits survive JSON persistence', () {
    final music = buildMusicInfo(name: 'Song', singer: 'A、B',
      source: MusicSource.wy, songId: 11, qualitys: [], durationMs: 218879,
      artists: [{'id': '12', 'name': 'A'}, {'id': '13', 'name': 'B'}]);
    final restored = MusicInfo.fromJson(jsonDecode(jsonEncode(music.toJson())));
    expect(restored.meta.raw['durationMs'], 218879);
    expect(restored.toJson(), music.toJson());
    expect(TrackArtistSdk.fromMetadata(restored).map((a) => a.id), ['12', '13']);
  });

  test('invalid optional metadata adds no raw keys', () {
    final music = buildMusicInfo(name: 'Song', singer: 'A',
      source: MusicSource.wy, songId: 11, qualitys: [], durationMs: -1,
      artists: [{'name': 'No ID'}, {'id': {}, 'name': 'Bad ID'}]);
    expect(music.meta.raw.containsKey('durationMs'), isFalse);
    expect(music.meta.raw.containsKey('artists'), isFalse);
  });

  test('WY public parser preserves both platform shapes and exact duration', () {
    for (final legacy in [false, true]) {
      final music = PlaylistSdk.parseWySong({
        'id': 11, 'name': 'Song',
        legacy ? 'duration' : 'dt': 242253,
        legacy ? 'artists' : 'ar': [
          {'id': 12, 'name': 'A'}, {'id': 13, 'name': 'B'},
        ],
      })!;
      expect(music.meta.raw['durationMs'], 242253);
      expect(music.interval, '04:02');
      expect(TrackArtistSdk.fromMetadata(music).map((a) => a.id), ['12', '13']);
      expect(MusicInfo.fromJson(jsonDecode(jsonEncode(music.toJson()))).meta.raw,
        music.meta.raw);
    }
  });

  test('WY malformed credits list is safe and missing IDs stay absent', () {
    for (final credits in [null, {}, [null, 1, {'name': 'A'}]]) {
      final music = PlaylistSdk.parseWySong({'id': 11, 'ar': credits, 'dt': 0})!;
      expect(TrackArtistSdk.fromMetadata(music), isEmpty);
      expect(music.meta.raw.containsKey('durationMs'), isFalse);
      expect(music.meta.raw.containsKey('artists'), isFalse);
    }
  });
}
