import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/shell/shell_bottom_area.dart';
import 'package:cy_shine_music/features/shell/shell_page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in [
    AppNavigationMode.singleCapsule,
    AppNavigationMode.dualCapsule,
  ]) {
    testWidgets('iOS $mode scrolls behind the home indicator', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 932);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: ShellBottomArea(
            navigationMode: mode,
            extent: mode == AppNavigationMode.dualCapsule ? 140 : 0,
            floatingExtent: mode == AppNavigationMode.dualCapsule ? 140 : 0,
            child: ShellPageFrame(
              location: '/',
              playlistBackLocation: '/songs',
              child: Builder(
                builder: (context) => ListView(
                  padding: EdgeInsets.only(
                    bottom: ShellBottomArea.contentPadding(context, 156),
                  ),
                  itemExtent: 100,
                  children: List.generate(20, (i) => Text('song $i')),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.getRect(find.byType(ListView)).bottom, 932);
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.getRect(find.text('song 19')).bottom,
        lessThanOrEqualTo(932 - 140),
      );
    });
  }
}
