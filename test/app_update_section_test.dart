import 'dart:io';

import 'package:cy_shine_music/core/app_info.dart';
import 'package:cy_shine_music/core/services/app_update_service.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/update/app_update_controller.dart';
import 'package:cy_shine_music/features/update/app_update_section.dart';
import 'package:cy_shine_music/features/update/ipa_download.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cy_shine_music/audio_intent');
  for (final saved in [true, false]) {
    testWidgets('IPA export result $saved reflects the system picker result', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final directory = Directory.systemTemp.createTempSync('update-export-test-');
      final file = File('${directory.path}/pending.ipa')..writeAsBytesSync([1, 2, 3]);
      final dio = Dio();
      final release = _release();
      final service = _Service(release);
      final controller = AppUpdateController(
        service: service, preferences: prefs,
        installedVersion: () async => '2.0.8',
      );
      await controller.check();
      final download = IpaDownload(dio: dio, stagingDirectory: () async => directory)
        ..file = file
        ..releaseTag = release.tagName
        ..releaseBuildNumber = release.buildNumber
        ..releaseSha256 = release.ipaSha256;
      final calls = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return saved;
      });
      final router = GoRouter(initialLocation: '/settings', routes: [
        GoRoute(path: '/settings', builder: (_, _) => const Scaffold(
          body: SingleChildScrollView(child: AppUpdateSection()),
        )),
      ]);
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        router.dispose();
        dio.close(force: true);
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(ProviderScope(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appUpdateControllerProvider.overrideWith((ref) => controller),
        ipaDownloadProvider.overrideWith((ref) => download),
        packageInfoProvider.overrideWith((ref) async => PackageInfo(
          appName: '栖弦', packageName: 'com.cyshine.music', version: '2.0.8', buildNumber: '6',
        )),
      ], child: MaterialApp.router(routerConfig: router)));
      await tester.pumpAndSettle();
      expect(find.text('TrollStore 更新安装'), findsOneWidget);
      expect(find.text('下载 IPA'), findsOneWidget);
      final save = find.text('保存到文件');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(calls.single.method, 'saveUpdateIpa');
      expect(calls.single.arguments, {'path': file.path});
      expect(find.text('已导出到你选择的位置'), saved ? findsOneWidget : findsNothing);
      expect(file.readAsBytesSync(), [1, 2, 3], reason: 'export does not mutate staging data');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      service.release = _release(build: 10);
      await controller.check();
      await tester.pumpAndSettle();
      expect(find.text('2.0.9 (10)'), findsOneWidget);
      expect(find.text('保存到文件'), findsNothing,
          reason: 'an older build with the same tag is not offered as the new package');
      expect(find.text('分享安装'), findsNothing);
      expect(file.existsSync(), isTrue, reason: 'refresh does not delete the previously downloaded file');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

AppRelease _release({int build = 9}) => AppRelease(
  version: Version(2, 0, 9), tagName: 'ios-v2.0.9', title: '2.0.9',
  manifestVersion: '2.0.9', buildNumber: build, ipaSha256: 'a' * 64,
  pageUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases/tag/ios-v2.0.9'),
  ipaUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases/download/ios-v2.0.9/CyShineMusic-unsigned.ipa'),
  notes: '完善在线更新体验。',
);

class _Service implements AppUpdateService {
  _Service(this.release);
  AppRelease release;
  @override
  Future<AppRelease?> fetchLatestRelease() async => release;
}
