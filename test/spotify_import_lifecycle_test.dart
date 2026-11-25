import 'dart:async';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/playlist_info.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/playlists/online_playlist_import_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final fails in [false, true]) {
    testWidgets('hidden import completes without stale loading: failure=$fails', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _Api();
      final visible = ValueNotifier(true);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        musicApiProvider.overrideWithValue(api),
      ]);
      addTearDown(() { container.dispose(); visible.dispose(); });
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: MaterialApp(home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          child: const OnlinePlaylistImportPage(),
          builder: (_, enabled, child) => TickerMode(enabled: enabled, child: child!),
        )),
      ));
      await tester.enterText(find.byType(TextField), 'hidden-import-id');
      await tester.tap(find.text('解析歌单'));
      await tester.pump();
      expect(api.calls, 1);
      visible.value = false;
      await tester.pump();
      if (fails) {
        api.result.completeError(StateError('offline fixture failure'));
      } else {
        api.result.complete(PlaylistInfo(id: 'hidden-id', name: 'Hidden result',
          source: MusicSource.wy, tracks: const []));
      }
      await tester.pump();
      visible.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Hidden result'), findsNothing);
      final parseButton = find.ancestor(of: find.text('解析歌单'),
          matching: find.byWidgetPredicate((widget) => widget is FilledButton));
      expect(tester.widget<FilledButton>(parseButton).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _Api extends MusicApi {
  final result = Completer<PlaylistInfo>();
  int calls = 0;
  @override
  Future<PlaylistInfo> parsePlaylist({required String input,
      MusicSource source = MusicSource.all, int? maxTracks}) {
    calls++;
    return result.future;
  }
}
