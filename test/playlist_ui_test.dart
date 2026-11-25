import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/download_capabilities.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/models/playlist_info.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/music_sources/music_source_controller.dart';
import 'package:cy_shine_music/core/services/download_service.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/downloads/download_history_store.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:cy_shine_music/features/playlists/lx_playlist_import.dart';
import 'package:cy_shine_music/features/playlists/playlist_browser_sheet.dart';
import 'package:cy_shine_music/features/playlists/playlist_detail_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_detail_toolbar_state.dart';
import 'package:cy_shine_music/features/playlists/playlist_management_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/playlists/widgets/playlist_track_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('management saves the outer card order only on completion', (
    tester,
  ) async {
    await _useCompactViewport(tester, size: const Size(390, 844));
    final playlists = [
      _playlist(id: 'a', name: '通勤'),
      _playlist(id: 'b', name: '夜晚'),
      _playlist(id: 'c', name: '现场'),
    ];
    final prefs = await _prefsWith(playlists);
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _testAppWithContainer(container, const PlaylistManagementPage()),
    );
    await tester.pumpAndSettle();

    List<String> savedIds() => [
      for (final playlist in container.read(localPlaylistsProvider))
        playlist.id,
    ];
    double cardY(String name) => tester.getCenter(find.text(name)).dy;

    Future<void> moveFirstCardToEnd() async {
      await tester.pumpAndSettle();
      expect(find.text('整理顺序'), findsOneWidget);
      expect(find.byTooltip('歌单选项'), findsNothing);
      final handles = find.byType(ReorderableDragStartListener);
      expect(handles, findsNWidgets(3));
      final rowExtent =
          tester.getCenter(handles.at(1)).dy -
          tester.getCenter(handles.first).dy;
      final start = tester.getCenter(handles.first);
      final gesture = await tester.startGesture(start);
      await tester.pump();
      for (var step = 1; step <= 12; step++) {
        await gesture.moveTo(start + Offset(0, rowExtent * 3 * step / 12));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(cardY('夜晚'), lessThan(cardY('现场')));
      expect(cardY('现场'), lessThan(cardY('通勤')));
      expect(savedIds(), ['a', 'b', 'c']);
    }

    await tester.tap(find.byTooltip('自定义排序'));
    await moveFirstCardToEnd();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(cardY('通勤'), lessThan(cardY('夜晚')));
    expect(find.byTooltip('歌单选项'), findsNWidgets(3));
    expect(savedIds(), ['a', 'b', 'c']);

    await tester.longPress(find.text('通勤'));
    await moveFirstCardToEnd();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(cardY('现场'), lessThan(cardY('通勤')));
    expect(savedIds(), ['b', 'c', 'a']);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);
    expect(
      reloaded.read(localPlaylistsProvider).map((playlist) => playlist.id),
      ['b', 'c', 'a'],
    );
  });

  testWidgets('playlist browser keeps management first and lists playlists', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final playlists = [
      _playlist(id: 'commute', name: '通勤'),
      for (var index = 1; index < 24; index++)
        _playlist(id: 'list-$index', name: '歌单 $index'),
    ];
    final prefs = await _prefsWith(playlists);

    await tester.pumpWidget(
      _testApp(
        prefs,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showPlaylistBrowserSheet(context),
                child: const Text('打开歌单'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开歌单'));
    await tester.pumpAndSettle();

    expect(find.text('歌单管理'), findsOneWidget);
    expect(find.text('通勤'), findsOneWidget);
    expect(find.text('0 首歌曲'), findsWidgets);
    await tester.drag(find.byType(ListView).last, const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('歌单管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add songs picker hides management and uses an action title', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith([_playlist(id: 'commute', name: '通勤')]);
    String? selected;

    await tester.pumpWidget(
      _testApp(
        prefs,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  selected = await showPlaylistBrowserSheet(
                    context,
                    mode: PlaylistBrowserMode.addSongs,
                  );
                },
                child: const Text('添加歌曲'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加歌曲'));
    await tester.pumpAndSettle();

    expect(find.text('添加歌曲到'), findsOneWidget);
    expect(find.text('我的歌单'), findsNothing);
    expect(find.text('歌单管理'), findsNothing);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);

    await tester.tap(find.text('通勤'));
    await tester.pumpAndSettle();
    expect(selected, '/playlists/commute');
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist browser keeps enough chrome height on a short screen', (
    tester,
  ) async {
    await _useCompactViewport(tester, size: const Size(640, 320));
    final prefs = await _prefsWith(const []);

    await tester.pumpWidget(
      _testApp(
        prefs,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showPlaylistBrowserSheet(context),
                child: const Text('打开歌单'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开歌单'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byType(DraggableScrollableSheet),
    );
    expect(sheet.minChildSize, greaterThanOrEqualTo(0.55));
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing an imported result also clears its saved draft', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith(const []);
    final parsed = PlaylistInfo(
      id: 'online-1',
      name: '已解析歌单',
      source: MusicSource.wy,
      tracks: const [],
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        musicApiProvider.overrideWithValue(_FakeMusicApi(parsed)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testAppWithContainer(container, const OnlinePlaylistImportPage()),
    );
    await tester.enterText(
      find.byType(TextField),
      'https://music.163.com/playlist?id=1',
    );
    await tester.ensureVisible(find.text('解析歌单'));
    await tester.tap(find.text('解析歌单'));
    await tester.pumpAndSettle();
    expect(find.text('已解析歌单'), findsOneWidget);
    expect(find.text('保存到本地歌单'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://music.163.com/playlist?id=2',
    );
    await tester.pump();
    expect(find.text('已解析歌单'), findsNothing);

    await tester.ensureVisible(find.text('解析歌单'));
    await tester.tap(find.text('解析歌单'));
    await tester.pumpAndSettle();
    expect(find.text('已解析歌单'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pump();
    expect(find.text('已解析歌单'), findsNothing);

    await tester.pumpWidget(_testAppWithContainer(container, const SizedBox()));
    await tester.pump();
    await tester.pumpWidget(
      _testAppWithContainer(container, const OnlinePlaylistImportPage()),
    );
    await tester.pump();

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller?.text, isEmpty);
    expect(find.text('已解析歌单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import source control stacks vertically for large text', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith(const []);

    await tester.pumpWidget(
      _testApp(
        prefs,
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: OnlinePlaylistImportPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sourceControl = tester.widget<SegmentedButton<MusicSource>>(
      find.byKey(const ValueKey('playlist-source-selector')),
    );
    expect(sourceControl.direction, Axis.vertical);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import source control is horizontal at standard phone width', (
    tester,
  ) async {
    await _useCompactViewport(tester, size: const Size(393, 852));
    final prefs = await _prefsWith(const []);

    await tester.pumpWidget(_testApp(prefs, const OnlinePlaylistImportPage()));
    await tester.pumpAndSettle();

    final sourceFinder = find.byKey(const ValueKey('playlist-source-selector'));
    final sourceControl = tester.widget<SegmentedButton<MusicSource>>(
      sourceFinder,
    );
    expect(sourceControl.direction, Axis.horizontal);
    expect(tester.getSize(sourceFinder).height, lessThan(72));
    expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_rounded), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
    expect(find.byIcon(Icons.library_music_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management and import pages fit a compact viewport', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith([_playlist(id: 'night', name: '夜晚循环')]);

    await tester.pumpWidget(_testApp(prefs, const PlaylistManagementPage()));
    await tester.pumpAndSettle();
    expect(find.text('新建歌单'), findsOneWidget);
    expect(find.text('在线导入'), findsOneWidget);
    expect(find.text('洛雪导入'), findsOneWidget);
    expect(find.text('夜晚循环'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_testApp(prefs, const OnlinePlaylistImportPage()));
    await tester.pumpAndSettle();
    final sourceControl = find.byKey(
      const ValueKey('playlist-source-selector'),
    );
    for (final name in ['自动', '酷我', '酷狗', '网易云', 'QQ', '咪咕']) {
      expect(
        find.descendant(of: sourceControl, matching: find.text(name)),
        findsOneWidget,
      );
    }
    final matchControl = find.byKey(
      const ValueKey('spotify-match-source-selector'),
    );
    expect(tester.widget<SegmentedButton<MusicSource>>(matchControl).selected, {
      MusicSource.wy,
    });
    expect(find.text('解析歌单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management imports a selected LX playlist file', (tester) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith(const []);
    final api = _BlockingCoverMusicApi();
    final payload = {
      'type': 'playListPart_v2',
      'data': {
        'id': 'love',
        'name': 'list__name_love',
        'list': [
          {
            'id': 'kg_1',
            'name': '导入歌曲',
            'singer': '歌手',
            'source': 'kg',
            'interval': '03:00',
            'meta': {
              'songId': '1',
              'albumName': '专辑',
              'qualitys': [
                {'type': '320k', 'size': '2048'},
              ],
            },
          },
        ],
      },
    };
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        musicApiProvider.overrideWithValue(api),
        lxPlaylistFilePickerProvider.overrideWithValue(
          () async => LxPlaylistPickedFile(
            name: 'love.json',
            bytes: utf8.encode(jsonEncode(payload)),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testAppWithContainer(container, const PlaylistManagementPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('洛雪导入'));
    await tester.pump();
    await tester.pump();

    expect(api.coverRequests, 1);
    expect(find.text('封面 0/1'), findsOneWidget);
    expect(container.read(localPlaylistsProvider), isEmpty);

    api.complete('https://img.test/imported-cover.jpg');
    await tester.pump(const Duration(milliseconds: 300));

    final playlists = container.read(localPlaylistsProvider);
    expect(playlists, hasLength(1));
    expect(playlists.single.name, '我的收藏');
    expect(playlists.single.tracks.single.name, '导入歌曲');
    expect(
      playlists.single.tracks.single.picUrl,
      'https://img.test/imported-cover.jpg',
    );
    expect(
      playlists.single.tracks.single.musicInfo?.meta.picUrl,
      'https://img.test/imported-cover.jpg',
    );
    expect(find.text('我的收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('empty playlist detail renders without overflow', (tester) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith([_playlist(id: 'empty', name: '空歌单')]);

    await tester.pumpWidget(
      _testApp(prefs, const PlaylistDetailPage(playlistId: 'empty')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('immersive-playlist-header')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('playlist-detail-info')), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byTooltip('搜索歌单歌曲'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsNothing);
    expect(find.text('空歌单'), findsOneWidget);
    expect(find.text('歌单还是空的'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visible missing playlist cover is resolved and persisted', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final track = PlaylistTrack.fromMusicInfo(
      _playlistMusic('missing-cover', '缺少封面的歌曲'),
    );
    final prefs = await _prefsWith([
      _playlist(id: 'cover-repair', name: '自动补图', tracks: [track]),
    ]);
    final api = _CoverResolvingMusicApi();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        musicApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testAppWithContainer(
        container,
        const PlaylistDetailPage(playlistId: 'cover-repair'),
      ),
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      final repaired = container
          .read(localPlaylistsProvider)
          .single
          .tracks
          .single
          .picUrl;
      if (repaired != null) break;
    }

    final repaired = container
        .read(localPlaylistsProvider)
        .single
        .tracks
        .single;
    expect(api.coverRequests, 1);
    expect(api.lastPreferCached, isFalse);
    expect(repaired.picUrl, 'https://img.test/missing-cover.jpg');
    expect(
      repaired.musicInfo?.meta.picUrl,
      'https://img.test/missing-cover.jpg',
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('playlist rename dialog closes safely on cancel and save', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final prefs = await _prefsWith([_playlist(id: 'rename', name: '原歌单名')]);

    await tester.pumpWidget(_testApp(prefs, const PlaylistManagementPage()));
    await tester.pumpAndSettle();

    Future<void> openRenameDialog() async {
      await tester.tap(find.byTooltip('歌单选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      expect(find.text('重命名歌单'), findsOneWidget);
    }

    await openRenameDialog();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('原歌单名'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await openRenameDialog();
    await tester.enterText(find.byType(TextField), '新的歌单名');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('新的歌单名'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('management only offers update for online playlists', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final online = _playlist(
      id: 'online',
      name: '收藏的榜单',
      tracks: [PlaylistTrack.fromMusicInfo(_playlistMusic('old', '旧歌曲'))],
      originPlaylistId: '3778678',
      originSourceCode: MusicSource.wy.code,
    );
    final local = _playlist(id: 'local', name: '本地新建');
    final prefs = await _prefsWith([online, local]);
    final api = _FakeMusicApi(
      PlaylistInfo(
        id: '3778678',
        name: '线上榜单',
        source: MusicSource.wy,
        tracks: [_playlistMusic('old', '新歌名'), _playlistMusic('new', '新歌曲')],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        musicApiProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testAppWithContainer(container, const PlaylistManagementPage()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('歌单选项').first);
    await tester.pumpAndSettle();
    expect(find.text('更新歌单'), findsOneWidget);
    await tester.tap(find.text('更新歌单'));
    await tester.pumpAndSettle();

    final refreshed = container
        .read(localPlaylistsProvider)
        .firstWhere((playlist) => playlist.id == online.id);
    expect(refreshed.tracks, hasLength(2));
    expect(refreshed.tracks.first.name, '新歌名');

    await tester.tap(find.byTooltip('歌单选项').last);
    await tester.pumpAndSettle();
    expect(find.text('更新歌单'), findsNothing);
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist batch download exits selection immediately', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final tracks = [
      PlaylistTrack.fromMusicInfo(_playlistMusic('track-1', '第一首')),
      PlaylistTrack.fromMusicInfo(_playlistMusic('track-2', '第二首')),
    ];
    final prefs = await _prefsWith([
      _playlist(id: 'batch', name: '批量歌单', tracks: tracks),
    ]);
    late _BlockingBatchDownloadService service;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        downloadServiceProvider.overrideWith(
          (ref) => service = _BlockingBatchDownloadService(ref),
        ),
        downloadCapabilitiesProvider.overrideWithValue(
          const AsyncData(
            DownloadCapabilities(
              sources: {
                MusicSource.wy: [Quality.k320],
              },
              availableSources: [MusicSource.wy],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testAppWithContainer(
        container,
        const PlaylistDetailPage(playlistId: 'batch'),
      ),
    );
    await tester.pumpAndSettle();

    final toolbar = container.read(playlistDetailToolbarStateProvider);
    expect(toolbar.attached, isTrue);
    expect(toolbar.hasDownloadable, isTrue);
    toolbar.onToggleBatch!();
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNWidgets(2));

    container.read(playlistDetailToolbarStateProvider).onToggleSelectAll!();
    await tester.pump();
    expect(find.text('下载 2 首'), findsOneWidget);

    await tester.tap(find.text('下载 2 首'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(service.calls, 1);
    expect(service.musics.map((music) => music.id), ['track-1', 'track-2']);
    expect(
      container.read(playlistDetailToolbarStateProvider).batchMode,
      isFalse,
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('下载 2 首'), findsNothing);
    expect(service.calls, 1);

    service.completeSuccessfully();
    await tester.pumpAndSettle();
    expect(
      container.read(playlistDetailToolbarStateProvider).batchMode,
      isFalse,
    );
    expect(find.text('下载 2 首'), findsNothing);
    expect(service.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('playlist batch download lets local tracks stay selectable', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final tempDir = Directory.systemTemp.createTempSync(
      'playlist-local-select-',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final localFile = File('${tempDir.path}${Platform.pathSeparator}local.mp3')
      ..writeAsStringSync('local');
    final localMusic = _playlistMusic('local-track', '本地歌');
    final localTrack = PlaylistTrack.fromMusicInfo(localMusic);
    final onlineTrack = PlaylistTrack.fromMusicInfo(
      _playlistMusic('online-track', '在线歌'),
    );
    final prefs = await _prefsWith([
      _playlist(id: 'mixed', name: '混合歌单', tracks: [localTrack, onlineTrack]),
    ]);
    late _BlockingBatchDownloadService service;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        downloadServiceProvider.overrideWith(
          (ref) => service = _BlockingBatchDownloadService(ref),
        ),
        downloadCapabilitiesProvider.overrideWithValue(
          const AsyncData(
            DownloadCapabilities(
              sources: {
                MusicSource.wy: [Quality.k320],
              },
              availableSources: [MusicSource.wy],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(downloadHistoryProvider.notifier)
        .addCompleted(
          music: localMusic,
          quality: Quality.k320,
          savedPath: localFile.path,
        );
    await container
        .read(settingsProvider.notifier)
        .setBatchDownloadQuality(OnlinePlaybackQuality.high);

    await tester.pumpWidget(
      _testAppWithContainer(
        container,
        const PlaylistDetailPage(playlistId: 'mixed'),
      ),
    );
    await tester.pumpAndSettle();

    container.read(playlistDetailToolbarStateProvider).onToggleBatch!();
    await tester.pumpAndSettle();
    container.read(playlistDetailToolbarStateProvider).onToggleSelectAll!();
    await tester.pump();
    expect(find.text('移出 2 首'), findsOneWidget);
    expect(find.text('播放 2 首'), findsOneWidget);
    expect(find.text('下载 1 首'), findsOneWidget);

    await tester.tap(find.text('下载 1 首'));
    await tester.pump();
    await tester.pump();
    expect(service.calls, 1);
    expect(service.musics.map((music) => music.id), ['online-track']);
    expect(service.qualityPreference, OnlinePlaybackQuality.high);
    expect(
      container.read(playlistDetailToolbarStateProvider).batchMode,
      isFalse,
    );

    service.completeSuccessfully();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'manually match a saved Spotify row and replace another occurrence',
    (tester) async {
      await _useCompactViewport(tester, size: const Size(390, 900));
      PlaylistTrack occurrence(int index, MusicInfo? match) =>
          PlaylistTrack.fromSpotify(
            SpotifyTrackMetadata(
              uri: 'spotify:track:same',
              title: '原始曲名',
              artist: '原始歌手',
              occurrence: index,
            ),
            match,
          );
      final pending = occurrence(0, null);
      final matched = occurrence(1, _playlistMusic('previous', '旧匹配'));
      final tracks = [pending, matched];
      final prefs = await _prefsWith([
        _playlist(
          id: 'spotify',
          name: '测试歌单',
          tracks: tracks,
          originPlaylistId: 'spotify-id',
          originSourceCode: 'spotify',
        ).copyWith(customTrackOrder: [matched.id, pending.id]),
      ]);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          musicApiProvider.overrideWithValue(_ManualMatchMusicApi()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _testAppWithContainer(
          container,
          const PlaylistDetailPage(playlistId: 'spotify'),
        ),
      );
      await tester.pumpAndSettle();
      Finder row(PlaylistTrack track) => find.byWidgetPredicate(
        (widget) =>
            widget is PlaylistTrackTile && widget.item.track.id == track.id,
      );
      LocalPlaylist saved() => container.read(localPlaylistsProvider).single;

      await tester.tap(find.byTooltip('批量操作'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(row(pending));
      await tester.tap(row(pending));
      await tester.pumpAndSettle();
      expect(find.text('已选中 1 项'), findsOneWidget);
      await tester.tap(find.byTooltip('退出批量管理'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(row(pending));
      await tester.tap(row(pending));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第一候选'));
      await tester.pumpAndSettle();
      expect(saved().tracks.map((track) => track.musicId), [
        'candidate-1',
        'previous',
      ]);

      await tester.ensureVisible(row(matched));
      await tester.drag(row(matched), const Offset(-240, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更换匹配').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('第二候选'));
      await tester.pumpAndSettle();
      expect(saved().tracks.map((track) => track.musicId), [
        'candidate-1',
        'candidate-2',
      ]);
      expect(saved().tracks.map((track) => track.id), [pending.id, matched.id]);
      expect(saved().customOrderedTracks.map((track) => track.id), [
        matched.id,
        pending.id,
      ]);
      expect(saved().tracks.map((track) => track.name), ['原始曲名', '原始曲名']);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('playlist detail copies one song and moves the batch', (
    tester,
  ) async {
    await _useCompactViewport(tester, size: const Size(390, 900));
    final first = PlaylistTrack.fromMusicInfo(_playlistMusic('first', '第一首'));
    final second = PlaylistTrack.fromMusicInfo(_playlistMusic('second', '第二首'));
    final prefs = await _prefsWith([
      _playlist(id: 'source', name: '原歌单', tracks: [first, second]),
      _playlist(id: 'destination', name: '目标歌单'),
    ]);
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _testAppWithContainer(
        container,
        const PlaylistDetailPage(playlistId: 'source'),
      ),
    );
    await tester.pumpAndSettle();
    final store = container.read(localPlaylistsProvider.notifier);
    final firstRow = find.text('第一首');
    await tester.ensureVisible(firstRow);
    await tester.drag(firstRow, const Offset(-270, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到歌单').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('添加歌曲到'), findsOneWidget);
    expect(find.text('1 个歌单'), findsOneWidget);
    await tester.tap(find.text('目标歌单'));
    await tester.pumpAndSettle();
    expect(store.byId('source')!.tracks.map((track) => track.id), [
      first.id,
      second.id,
    ]);
    expect(store.byId('destination')!.tracks.single.id, first.id);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('批量操作'));
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    final batchBar = find.byKey(const ValueKey('playlist-batch-bottom-bar'));
    final moveAction = find.descendant(
      of: batchBar,
      matching: find.text('移动到歌单'),
    );
    expect(moveAction, findsOneWidget);
    await tester.tap(moveAction);
    await tester.pumpAndSettle();
    expect(find.text('移动歌曲到'), findsOneWidget);
    await tester.tap(find.text('目标歌单'));
    await tester.pumpAndSettle();
    expect(store.byId('source')!.tracks, isEmpty);
    expect(store.byId('destination')!.tracks.map((track) => track.id), [
      second.id,
      first.id,
    ]);
    expect(
      find.byKey(const ValueKey('playlist-batch-bottom-bar')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('swipe to remove a playlist track without confirmation', (
    tester,
  ) async {
    await _useCompactViewport(tester);
    final tracks = [
      PlaylistTrack.fromMusicInfo(_playlistMusic('track-1', '第一首')),
    ];
    final prefs = await _prefsWith([
      _playlist(id: 'swipe', name: '左滑歌单', tracks: tracks),
    ]);

    await tester.pumpWidget(
      _testApp(prefs, const PlaylistDetailPage(playlistId: 'swipe')),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一首'), findsOneWidget);

    await tester.drag(find.text('第一首'), const Offset(-260, 0));
    await tester.pumpAndSettle();
    expect(find.text('更换匹配'), findsNothing);
    await tester.tap(find.text('移除'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('从歌单中移除？'), findsNothing);
    expect(find.text('第一首'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}

Future<void> _useCompactViewport(
  WidgetTester tester, {
  Size size = const Size(320, 720),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

Future<SharedPreferences> _prefsWith(List<LocalPlaylist> playlists) async {
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [
      for (final playlist in playlists) jsonEncode(playlist.toJson()),
    ],
  });
  return SharedPreferences.getInstance();
}

Widget _testApp(SharedPreferences prefs, Widget home) {
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: home,
    ),
  );
}

Widget _testAppWithContainer(ProviderContainer container, Widget home) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: home,
    ),
  );
}

class _BlockingBatchDownloadService extends DownloadService {
  _BlockingBatchDownloadService(super.ref);

  final Completer<List<BatchDownloadResult>> _completer = Completer();
  List<MusicInfo> musics = const [];
  int calls = 0;

  @override
  Future<List<BatchDownloadResult>> downloadMany({
    required List<MusicInfo> musics,
    EmbedRequest embed = const EmbedRequest.richest(),
    int concurrency = DownloadService.batchConcurrency,
    OnlinePlaybackQuality qualityPreference = OnlinePlaybackQuality.highest,
  }) {
    calls += 1;
    this.musics = List.of(musics);
    this.qualityPreference = qualityPreference;
    return _completer.future;
  }

  OnlinePlaybackQuality qualityPreference = OnlinePlaybackQuality.highest;

  void completeSuccessfully() {
    _completer.complete([
      for (final music in musics)
        BatchDownloadResult(
          music: music,
          result: DownloadResult(path: 'D:/Music/${music.id}.mp3'),
        ),
    ]);
  }
}

class _FakeMusicApi extends MusicApi {
  _FakeMusicApi(this.playlist);

  final PlaylistInfo playlist;

  @override
  Future<PlaylistInfo> parsePlaylist({
    required String input,
    MusicSource source = MusicSource.all,
    int? maxTracks,
  }) async {
    return playlist;
  }
}

class _ManualMatchMusicApi extends MusicApi {
  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async => SearchResponse(
    list: [
      _playlistMusic('candidate-1', '第一候选'),
      _playlistMusic('candidate-2', '第二候选'),
    ],
    page: page,
    limit: limit,
    allPage: 1,
    total: 2,
    source: source,
  );

  @override
  Future<String?> getPicUrl({
    required MusicInfo musicInfo,
    bool preferCached = true,
  }) async => null;
}

class _CoverResolvingMusicApi extends MusicApi {
  int coverRequests = 0;
  bool? lastPreferCached;

  @override
  Future<String?> getPicUrl({
    required MusicInfo musicInfo,
    bool preferCached = true,
  }) async {
    coverRequests++;
    lastPreferCached = preferCached;
    return 'https://img.test/${musicInfo.id}.jpg';
  }
}

class _BlockingCoverMusicApi extends MusicApi {
  final Completer<String?> _completer = Completer<String?>();
  int coverRequests = 0;

  @override
  Future<String?> getPicUrl({
    required MusicInfo musicInfo,
    bool preferCached = true,
  }) {
    coverRequests++;
    return _completer.future;
  }

  void complete(String? url) => _completer.complete(url);
}

LocalPlaylist _playlist({
  required String id,
  required String name,
  List<PlaylistTrack> tracks = const [],
  String? originPlaylistId,
  String? originSourceCode,
}) {
  final now = DateTime.utc(2026, 7, 20);
  return LocalPlaylist(
    id: id,
    name: name,
    tracks: tracks,
    createdAt: now,
    updatedAt: now,
    originPlaylistId: originPlaylistId,
    originSourceCode: originSourceCode,
  );
}

MusicInfo _playlistMusic(String id, String name) {
  return MusicInfo.fromJson({
    'id': id,
    'name': name,
    'singer': '在线歌手',
    'source': MusicSource.wy.code,
    'interval': '03:30',
    'meta': {
      'songId': id,
      'albumName': '在线专辑',
      'qualitys': [
        {'type': Quality.k320.code, 'size': '1024'},
      ],
    },
  });
}
