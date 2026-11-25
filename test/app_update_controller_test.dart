import 'dart:convert';

import 'package:cy_shine_music/core/services/app_update_service.dart';
import 'package:cy_shine_music/features/update/app_update_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late _Service service;
  var now = DateTime(2026, 11, 25, 12);
  AppUpdateController controller(String installed, {String build = '8'}) => AppUpdateController(
    service: service, preferences: prefs,
    installedVersion: () async => installed, installedBuild: () async => build, clock: () => now,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = _Service();
    now = DateTime(2026, 11, 25, 12);
  });

  test('pending release survives restart and suppresses automatic requests', () async {
    final first = controller('2.0.8');
    expect(await first.check(), UpdateCheckResult.updateAvailable);
    expect(first.release!.notes, '完善在线更新体验。');
    first.dispose();
    final restarted = controller('2.0.8');
    await restarted.initialize();
    expect(restarted.release!.version, Version(2, 0, 9));
    now = now.add(const Duration(days: 2));
    await restarted.check(automatic: true);
    expect(service.calls, 1);
    restarted.dispose();
  });

  test('manual failure keeps cached information, manual refresh replaces it', () async {
    final c = controller('2.0.8');
    await c.check();
    service.error = const FormatException('invalid');
    expect(await c.check(), UpdateCheckResult.failed);
    expect(c.release!.version, Version(2, 0, 9));
    expect(c.message, contains('数据'));
    service.error = null;
    service.latest = _release('2.0.10');
    await c.check();
    expect(c.release!.version, Version(2, 0, 10));
    expect(service.calls, 3);
    c.dispose();
  });

  test('installed cached version clears cache and resumes automatic checks', () async {
    final old = controller('2.0.8');
    await old.check();
    old.dispose();
    final upgraded = controller('2.0.9');
    await upgraded.initialize();
    expect(upgraded.release, isNull);
    expect(await upgraded.check(automatic: true), UpdateCheckResult.upToDate);
    expect(service.calls, 2);
    upgraded.dispose();
    final again = controller('2.0.9');
    await again.initialize();
    expect(again.release, isNull);
    again.dispose();
  });

  test('same-version newer build remains pending across restart until installed', () async {
    service.latest = _release('2.0.9', build: 9, digest: 'a' * 64);
    final first = controller('2.0.9', build: '8');
    expect(await first.check(), UpdateCheckResult.updateAvailable);
    first.dispose();
    final restarted = controller('2.0.9', build: '8');
    await restarted.initialize();
    expect(restarted.release!.buildNumber, 9);
    expect(restarted.release!.ipaSha256, 'a' * 64);
    now = now.add(const Duration(days: 3));
    expect(await restarted.check(automatic: true), UpdateCheckResult.skipped);
    expect(service.calls, 1);
    service.latest = _release('2.0.9', build: 10, digest: 'b' * 64);
    expect(await restarted.check(), UpdateCheckResult.updateAvailable);
    expect(restarted.release!.buildNumber, 10);
    expect(service.calls, 2);
    restarted.dispose();
    final upgraded = controller('2.0.9', build: '10');
    await upgraded.initialize();
    expect(upgraded.release, isNull);
    expect(await upgraded.check(automatic: true), UpdateCheckResult.upToDate);
    expect(service.calls, 3);
    upgraded.dispose();
  });

  test('legacy pending record keeps its reminder but requires a manifest before download', () async {
    final old = _release('2.0.9');
    await prefs.setString('ios_app_update_pending_v1', jsonEncode({
      'tag': old.tagName, 'page': old.pageUri.toString(), 'title': old.title,
      'notes': old.notes, 'ipa': old.ipaUri.toString(), 'hasSha256': false,
    }));
    final c = controller('2.0.8');
    await c.initialize();
    expect(c.release!.version, Version(2, 0, 9));
    expect(c.release!.ipaUri, isNull);
    expect(c.message, contains('校验信息'));
    expect(await c.check(automatic: true), UpdateCheckResult.skipped);
    expect(service.calls, 0);
    service.latest = _release('2.0.9', build: 9, digest: 'a' * 64);
    expect(await c.check(), UpdateCheckResult.updateAvailable);
    expect(service.calls, 1);
    expect(c.release!.ipaUri, isNotNull);
    expect(c.release!.ipaSha256, 'a' * 64);
    c.dispose();
  });

  test('invalid official version is a failure rather than newest', () async {
    service.latest = AppRelease(version: Version(2, 0, 9), tagName: 'invalid',
      pageUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases'), title: 'invalid');
    final c = controller('2.0.9');
    expect(await c.check(), UpdateCheckResult.failed);
    expect(c.release, isNull);
    expect(c.message, contains('数据'));
    c.dispose();
  });

  test('automatic no-update and failed checks throttle 15 minutes across restart', () async {
    service.latest = _release('2.0.8');
    final c = controller('2.0.8');
    await c.check(automatic: true);
    c.dispose();
    final again = controller('2.0.8');
    now = now.add(const Duration(minutes: 14));
    expect(await again.check(automatic: true), UpdateCheckResult.skipped);
    expect(service.calls, 1);
    now = now.add(const Duration(minutes: 1));
    service.error = Exception('offline');
    expect(await again.check(automatic: true), UpdateCheckResult.failed);
    expect(again.message, isNull);
    await again.check(automatic: true);
    expect(service.calls, 2);
    again.dispose();
  });
}
AppRelease _release(String version, {int? build, String? digest}) => AppRelease(
  version: Version.parse(version), tagName: 'ios-v$version', title: version,
  manifestVersion: version, buildNumber: build, ipaSha256: digest,
  pageUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases/tag/ios-v$version'),
  ipaUri: Uri.parse('https://github.com/wm0104/CyShineMusic-iOS/releases/download/ios-v$version/CyShineMusic-unsigned.ipa'),
  notes: '完善在线更新体验。',
);
class _Service implements AppUpdateService {
  AppRelease latest = _release('2.0.9');
  Object? error;
  int calls = 0;
  @override
  Future<AppRelease?> fetchLatestRelease() async {
    calls++;
    if (error != null) throw error!;
    return latest;
  }
}
