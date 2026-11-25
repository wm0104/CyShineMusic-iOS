import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PictureRecorder;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/services/embedded_artwork_cache.dart';
import 'package:cy_shine_music/core/services/flac_metadata_writer.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/playlist_cover_image.dart';
import 'package:cy_shine_music/features/playlists/playlist_detail_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/widgets/immersive_playlist_chrome.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_artwork.dart';

const _size = 60.0;
const _placeholder = SizedBox(key: ValueKey('artwork-placeholder'));
const _firstUrl = 'https://img.test/first.jpg';
const _secondUrl = 'https://img.test/second.jpg';
const _missingUrl = 'https://img.test/missing.jpg';

void main() {
  testWidgets('only usable art in the first four fills the whole cover', (
    tester,
  ) async {
    await _cacheNetworkArtwork(_firstUrl);
    final missing = Completer<ImageInfo>();
    await _cacheNetworkArtwork(_missingUrl, image: missing.future);
    final first = _track('first', url: _firstUrl);
    final fifth = _track('fifth', url: _secondUrl);
    final tracks = [
      _track('empty'),
      first,
      _track('invalid', url: '/unsupported.jpg'),
      _track('missing', url: _missingUrl),
      fifth,
    ];
    await _pumpCover(tester, _playlist(tracks.take(1).toList()));
    expect(find.byKey(_placeholder.key!), findsOneWidget);

    await _pumpCover(tester, _playlist(tracks));
    missing.completeError(StateError('cover is unavailable'));
    await tester.pumpAndSettle();
    final image = find.byType(PlaylistArtworkImage);
    expect(image, findsOneWidget);
    expect(tester.getSize(image), const Size.square(_size));
    expect(_networkUrls(tester), [_firstUrl]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved order determines each quadrant and uses embedded art', (
    tester,
  ) async {
    await _cacheNetworkArtwork(_firstUrl);
    await _cacheNetworkArtwork(_secondUrl);
    final path = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('playlist_artwork_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/track.flac');
      await file.writeAsBytes([
        0x66, 0x4c, 0x61, 0x43, // fLaC
        0x80, 0, 0, 34, // STREAMINFO
        ...List<int>.filled(34, 0),
        0, // audio
      ]);
      await FlacMetadataWriter.write(
        file.path,
        pictureBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAA'
          'AARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAASSURBVBhXY7ij'
          'rPsfhKEM3f8ATTgIrTbBk9sAAAAASUVORK5CYII=',
        ),
        pictureMimeType: 'image/png',
      );
      final bytes = await EmbeddedArtworkCache.load(file.path);
      await _cacheImage(MemoryImage(bytes!));
      return file.path;
    });
    final first = _track('first', url: _firstUrl);
    final second = _track('second', url: _secondUrl);
    final local = _track('embedded', localPath: path);
    final empty = _track('empty');
    final later = _track('later');
    final playlist = _playlist([first, empty, local, later, second]);

    await _pumpCover(tester, playlist);
    final image = find.byType(PlaylistArtworkImage);
    expect(image, findsNWidgets(2));
    expect(_networkUrls(tester), [_firstUrl]);
    expect(find.byKey(_placeholder.key!), findsNWidgets(2));

    await _pumpCover(
      tester,
      playlist.copyWith(
        customTrackOrder: [
          for (final track in [second, empty, first, local, later])
            track.identityKey,
        ],
      ),
    );
    expect(image, findsNWidgets(3));
    expect(_networkUrls(tester), [_secondUrl, _firstUrl]);
    expect(_providers(tester).last, isA<MemoryImage>());
    final origin = tester.getTopLeft(find.byType(PlaylistCover));
    expect(tester.getTopLeft(image.at(0)), origin);
    expect(tester.getTopLeft(image.at(1)), origin + const Offset(0, 30));
    expect(tester.getTopLeft(image.at(2)), origin + const Offset(30, 30));
    expect(tester.getSize(image.first), const Size.square(_size / 2));
    expect(find.byKey(_placeholder.key!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'LX imports use their first candidate and online imports keep the explicit cover',
    (tester) async {
      final playlist = _playlist([
        _track('first', url: _firstUrl),
        _track('second', url: _secondUrl),
      ], id: 'lx-1');
      await _pumpCover(tester, playlist, settle: false);
      expect(find.byType(ManualPlaylistArtworkBuilder), findsNothing);
      expect(
        tester
            .widget<PlaylistTrackArtwork>(find.byType(PlaylistTrackArtwork))
            .picUrl,
        _firstUrl,
      );

      await _pumpCover(
        tester,
        _playlist(playlist.tracks, id: 'online-1', coverUrl: _secondUrl),
        settle: false,
      );
      expect(find.byType(ManualPlaylistArtworkBuilder), findsNothing);
      expect(find.byType(PlaylistTrackArtwork), findsNothing);
      expect(
        tester.widget<PlaylistCoverImage>(find.byType(PlaylistCoverImage)).url,
        _secondUrl,
      );
    },
  );

  testWidgets('compact and wide detail keep the saved cover during search', (
    tester,
  ) async {
    for (final url in [_firstUrl, _secondUrl]) {
      await _cacheNetworkArtwork(url, size: 1200);
      await _cacheNetworkArtwork(
        url,
        size: 156,
        policy: ResizeImagePolicy.exact,
      );
    }
    final first = _track('first', url: _firstUrl);
    final second = _track('second', url: _secondUrl);
    final playlist = _playlist([
      first,
      second,
    ]).copyWith(customTrackOrder: [second.identityKey, first.identityKey]);
    SharedPreferences.setMockInitialValues({
      localPlaylistsStorageKey: [jsonEncode(playlist.toJson())],
      'playlist_artwork_colors_enabled': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: PlaylistDetailPage(playlistId: playlist.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('immersive-playlist-header')),
      findsOneWidget,
    );
    expect(_networkUrls(tester), [_secondUrl, _firstUrl]);

    await tester.tap(find.byTooltip('搜索歌单歌曲'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'first');
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(_networkUrls(tester), [_secondUrl, _firstUrl]);

    await container.read(settingsProvider.notifier).setCarPadModeEnabled(true);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist-wide-info-pane')),
      findsOneWidget,
    );
    expect(_networkUrls(tester), [_secondUrl, _firstUrl]);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpCover(
  WidgetTester tester,
  LocalPlaylist playlist, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: PlaylistCover(
            playlist: playlist,
            size: _size,
            radius: 14,
            placeholder: _placeholder,
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> _cacheNetworkArtwork(
  String url, {
  Future<ImageInfo>? image,
  int size = 180,
  ResizeImagePolicy policy = ResizeImagePolicy.fit,
}) => _cacheImage(
  networkPlaylistArtworkProvider(url, size: size)!,
  image: image,
  size: size,
  policy: policy,
);

Future<void> _cacheImage(
  ImageProvider<Object> provider, {
  Future<ImageInfo>? image,
  int size = 180,
  ResizeImagePolicy policy = ResizeImagePolicy.fit,
}) async {
  final resized = ResizeImage(
    provider,
    width: size,
    height: size,
    policy: policy,
  );
  final key = await resized.obtainKey(ImageConfiguration.empty);
  final cache = PaintingBinding.instance.imageCache;
  cache.putIfAbsent(key, () {
    if (image != null) return OneFrameImageStreamCompleter(image);
    final recorder = PictureRecorder();
    Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
    final picture = recorder.endRecording();
    final pixels = picture.toImageSync(2, 2);
    picture.dispose();
    return OneFrameImageStreamCompleter(Future.value(ImageInfo(image: pixels)));
  });
  addTearDown(() => cache.evict(key));
}

Iterable<ImageProvider> _providers(WidgetTester tester) => tester
    .widgetList<PlaylistArtworkImage>(find.byType(PlaylistArtworkImage))
    .map((widget) => (widget.provider! as ResizeImage).imageProvider);

Iterable<String> _networkUrls(WidgetTester tester) => _providers(
  tester,
).whereType<CachedNetworkImageProvider>().map((provider) => provider.url);

LocalPlaylist _playlist(
  List<PlaylistTrack> tracks, {
  String id = 'local-1',
  String? coverUrl,
}) {
  final now = DateTime(2026);
  return LocalPlaylist(
    id: id,
    name: '封面测试',
    createdAt: now,
    updatedAt: now,
    tracks: tracks,
    coverUrl: coverUrl,
  );
}

PlaylistTrack _track(String id, {String? url, String? localPath}) =>
    PlaylistTrack(
      musicId: id,
      name: id,
      singer: '歌手',
      albumName: '',
      sourceCode: 'kw',
      qualityCode: '128k',
      picUrl: url,
      localPath: localPath,
    );
