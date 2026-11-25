import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/core/services/embedded_artwork_cache.dart';
import 'package:cy_shine_music/features/playlists/playlist_detail_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_management_page.dart';
import 'package:cy_shine_music/features/playlists/playlist_models.dart';
import 'package:cy_shine_music/features/playlists/playlist_store.dart';
import 'package:cy_shine_music/features/shell/shell_toolbar_visibility.dart';
import 'package:cy_shine_music/features/player/player_audio_handler.dart';
import 'package:cy_shine_music/features/player/player_controller.dart';
import 'package:cy_shine_music/features/songs/widgets/songs_placeholders.dart';
import 'package:cy_shine_music/router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('custom entry opens full draft; cancel restores toolbar without saving', (tester) async {
    final container = await _pumpPlaylist(tester);
    await _startOrdering(tester);
    expect(find.text('整理顺序'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    expect(container.read(shellToolbarVisibleProvider), isFalse);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('playlist-play-all'))).onPressed, isNull);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const ValueKey('playlist-download-action')), findsNothing);
    await _moveFirstToEnd(tester);
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
  });

  testWidgets('complete persists custom order, reload defaults custom, rules retain baseline', (tester) async {
    final container = await _pumpPlaylist(tester);
    final baseline = container.read(localPlaylistsProvider).single.tracks.map((track) => track.identityKey).toList();
    await _startOrdering(tester);
    await _moveFirstToEnd(tester);
    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider).single.customTrackOrder,
      [baseline[1], baseline[2], baseline[0]]);
    expect(container.read(localPlaylistsProvider).single.tracks.map((track) => track.identityKey), baseline);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    _expectOrder(tester, ['Bravo', 'Charlie', 'Alpha']);

    final prefs = container.read(sharedPreferencesProvider);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final reloaded = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      playerControllerProvider.overrideWith((ref) => throw StateError('Ordering must not access the player')),
    ]);
    addTearDown(reloaded.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: reloaded,
      child: MaterialApp(home: const PlaylistDetailPage(playlistId: 'order')),
    ));
    await tester.pumpAndSettle();
    _expectOrder(tester, ['Bravo', 'Charlie', 'Alpha']);
    await tester.tap(find.byKey(const ValueKey('playlist-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
    await tester.tap(find.byKey(const ValueKey('playlist-sort-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('升序'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search exits before ordering and saves the complete playlist', (tester) async {
    final container = await _pumpPlaylist(tester);
    await tester.tap(find.byTooltip('搜索歌单歌曲'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(SongsSearchBar), 'Bravo');
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    await _startOrdering(tester);
    expect(find.byType(SongsSearchBar), findsNothing);
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    await _moveFirstToEnd(tester);
    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider).single.customOrderedTracks.map((track) => track.name), ['Bravo', 'Charlie', 'Alpha']);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide layout can reorder and system back cancels without saving', (tester) async {
    final container = await _pumpPlaylist(tester, size: const Size(1200, 800));
    expect(find.byKey(const ValueKey('playlist-wide-layout')), findsOneWidget);
    await _startOrdering(tester);
    await _moveFirstToEnd(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS edge back exits playlist modes before leaving the detail', (
    tester,
  ) async {
    final container = await _pumpPlaylist(tester, withAppRouter: true);

    Future<void> swipeBack() async {
      await tester.dragFrom(const Offset(4, 400), const Offset(210, 0));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byTooltip('搜索歌单歌曲'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出搜索'), findsOneWidget);
    await swipeBack();
    expect(find.byTooltip('退出搜索'), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playlist-batch-button')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出批量管理'), findsOneWidget);
    await swipeBack();
    expect(find.byTooltip('退出批量管理'), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);

    await _startOrdering(tester);
    await _moveFirstToEnd(tester);
    await swipeBack();
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    _expectOrder(tester, ['Alpha', 'Bravo', 'Charlie']);

    await swipeBack();
    expect(find.byType(PlaylistManagementPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('concurrent removal rejects stale completion instead of losing songs', (tester) async {
    final container = await _pumpPlaylist(tester);
    await _startOrdering(tester);
    final removed = container.read(localPlaylistsProvider).single.tracks.last.identityKey;
    await container.read(localPlaylistsProvider.notifier).removeTrack('order', removed);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('完成'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(container.read(localPlaylistsProvider).single.customTrackOrder, isNull);
    expect(container.read(localPlaylistsProvider).single.tracks.length, 2);
    expect(find.text('整理顺序'), findsOneWidget);
    expect(find.text('歌单歌曲已变化，请重新整理'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(shellToolbarVisibleProvider), isTrue);
    // pumpAndSettle stops once animation frames settle, not when the toast's
    // three-second auto-close timer expires.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _pumpPlaylist(WidgetTester tester, {
  Size size = const Size(390, 1000),
  bool withAppRouter = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final directory = Directory.systemTemp.createTempSync('playlist-order-ui-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final tracks = [
    for (final name in ['Alpha', 'Bravo', 'Charlie'])
      PlaylistTrack(
        musicId: name,
        name: name,
        singer: 'Local artist',
        albumName: '',
        sourceCode: 'local',
        qualityCode: '128k',
        localPath: (File('${directory.path}/$name.mp3')..writeAsBytesSync([])).path,
      ),
  ];
  await tester.runAsync(() async {
    for (final track in tracks) {
      await EmbeddedArtworkCache.load(track.localPath!);
    }
  });
  SharedPreferences.setMockInitialValues({
    localPlaylistsStorageKey: [jsonEncode(LocalPlaylist(
      id: 'order', name: 'Order test', tracks: tracks,
      createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
    ).toJson())],
  });
  final prefs = await SharedPreferences.getInstance();
  final handler = withAppRouter ? PlayerAudioHandler() : null;
  final router = withAppRouter
      ? createAppRouter(initialLocation: '/playlists/order?from=manage')
      : null;
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    if (handler != null)
      playerAudioHandlerProvider.overrideWithValue(handler)
    else
      playerControllerProvider.overrideWith((ref) => throw StateError('Ordering must not access the player or its queue')),
  ]);
  addTearDown(() {
    router?.dispose();
    container.dispose();
    if (handler != null) unawaited(handler.disposeHandler());
  });
  if (size.width >= 840) {
    await container.read(settingsProvider.notifier).setCarPadModeEnabled(true);
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: router == null
        ? MaterialApp(home: const PlaylistDetailPage(playlistId: 'order'))
        : MaterialApp.router(
            routerConfig: router,
            theme: ThemeData(platform: TargetPlatform.iOS),
          ),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _startOrdering(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('playlist-sort-button'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.tap(find.text('自定义排序'));
  await tester.pumpAndSettle();
}

Future<void> _moveFirstToEnd(WidgetTester tester) async {
  final handles = find.byType(ReorderableDragStartListener);
  final start = tester.getCenter(handles.first);
  final end = tester.getCenter(handles.last);
  final rowExtent = (end.dy - start.dy) / 2;
  final gesture = await tester.startGesture(start);
  await tester.pump();
  // Cross the last row with the proxy's leading edge, not just the pointer.
  // Allow intermediate gap animations to update the SDK's target geometry.
  await gesture.moveBy(const Offset(0, 10));
  await tester.pump();
  final destination = end + Offset(0, rowExtent);
  for (var step = 1; step <= 12; step++) {
    await gesture.moveTo(
      Offset.lerp(start + const Offset(0, 10), destination, step / 12)!,
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
  _expectOrder(tester, ['Bravo', 'Charlie', 'Alpha']);
}

void _expectOrder(WidgetTester tester, List<String> names) {
  for (var index = 1; index < names.length; index++) {
    expect(tester.getTopLeft(find.text(names[index - 1])).dy,
      lessThan(tester.getTopLeft(find.text(names[index])).dy));
  }
}
