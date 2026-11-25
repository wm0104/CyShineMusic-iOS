import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_info.dart';
import '../../core/services/app_logger.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/app_update_version.dart';
import '../../core/storage/settings_store.dart';

enum UpdateCheckResult { updateAvailable, upToDate, failed, alreadyChecking, skipped }

final appUpdateControllerProvider = ChangeNotifierProvider<AppUpdateController>((ref) {
  return AppUpdateController(
    service: ref.watch(appUpdateServiceProvider),
    preferences: ref.read(sharedPreferencesProvider),
    installedVersion: () async => (await ref.read(packageInfoProvider.future)).version,
    installedBuild: () async => (await ref.read(packageInfoProvider.future)).buildNumber,
  );
});

/// iOS only: pending metadata is a reminder, not a claim the remote IPA is available.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required AppUpdateService service,
    required SharedPreferences preferences,
    required Future<String> Function() installedVersion,
    Future<String> Function()? installedBuild,
    DateTime Function()? clock,
  }) : _service = service, _prefs = preferences,
       _installedVersion = installedVersion,
       _installedBuild = installedBuild ?? (() async => ''),
       _clock = clock ?? DateTime.now;

  static const _cacheKey = 'ios_app_update_pending_v1';
  static const _attemptKey = 'ios_app_update_attempt_v1';
  final AppUpdateService _service;
  final SharedPreferences _prefs;
  final Future<String> Function() _installedVersion;
  final Future<String> Function() _installedBuild;
  final DateTime Function() _clock;
  Future<void>? _initializing;
  bool _disposed = false;
  bool checking = false;
  AppRelease? release;
  String? message;
  DateTime? _lastAttempt;

  Future<void> initialize() => _initializing ??= _hydrate();

  Future<void> _hydrate() async {
    final attempt = _prefs.getInt(_attemptKey);
    if (attempt != null) _lastAttempt = DateTime.fromMillisecondsSinceEpoch(attempt);
    final cached = _prefs.getString(_cacheKey);
    if (cached == null) return;
    try {
      final data = jsonDecode(cached) as Map<String, dynamic>;
      final tag = data['tag'] as String;
      final versionText = data['version'] as String? ?? tag;
      final version = OfficialAppVersion.tryParse(versionText);
      final tagVersion = OfficialAppVersion.tryParse(tag);
      final build = data['build'];
      final digest = data['ipaSha256'];
      final page = Uri.parse(data['page'] as String);
      if (version == null || tagVersion == null || version.isPrerelease ||
          tagVersion.isPrerelease || version.core != tagVersion.core ||
          (build != null && (build is! int || build <= 0)) ||
          (digest != null && (digest is! String || digest.length != 64 ||
              !RegExp(r'^[a-fA-F0-9]+$').hasMatch(digest))) ||
          !isOfficialUpdateReleaseUri(page, tag)) {
        throw const FormatException('Invalid cached release');
      }
      Uri? asset(String key, String name) {
        final raw = data[key] as String?;
        if (raw == null) return null;
        final uri = Uri.parse(raw);
        if (!isOfficialUpdateAssetUri(uri, tagName: tag, fileName: name)) {
          throw const FormatException('Untrusted cached update asset');
        }
        return uri;
      }
      final cachedIpa = asset('ipa', iosUpdateIpaName);
      final hasManifestPackage = build is int && digest is String;
      final pending = AppRelease(
        version: Version(version.components[0], version.components[1], version.components[2]),
        manifestVersion: versionText, buildNumber: build as int?, ipaSha256: digest as String?,
        tagName: tag, pageUri: page,
        title: data['title'] as String, notes: data['notes'] as String,
        ipaUri: hasManifestPackage ? cachedIpa : null,
        sha256Uri: asset('sha256', '$iosUpdateIpaName.sha256'),
        hasSha256: data['hasSha256'] == true,
      );
      if (!isNewerOfficialVersion(remoteVersion: versionText, remoteBuild: pending.buildNumber,
          installedVersion: await _installedVersion(), installedBuild: await _installedBuild())) {
        await _prefs.remove(_cacheKey);
        await _prefs.remove(_attemptKey);
        _lastAttempt = null;
        return;
      }
      release = pending;
      if (cachedIpa != null && !hasManifestPackage) {
        message = '已保留上次更新信息，请重新检查以获取安装包校验信息';
      }
      _notify();
    } catch (error) {
      await AppLogger.write('update', 'read pending cache failed: $error');
      await _prefs.remove(_cacheKey);
    }
  }

  Future<UpdateCheckResult> check({bool automatic = false}) async {
    await initialize();
    if (_disposed) return UpdateCheckResult.skipped;
    if (checking) return UpdateCheckResult.alreadyChecking;
    if (automatic && (release != null ||
        (_lastAttempt != null && _clock().difference(_lastAttempt!) < const Duration(minutes: 15)))) {
      return UpdateCheckResult.skipped;
    }
    checking = true;
    if (!automatic) message = null;
    _notify();
    try {
      final installed = await _installedVersion();
      final installedBuild = await _installedBuild();
      if (OfficialAppVersion.tryParse(installed) == null) {
        throw const FormatException('Invalid installed version');
      }
      _lastAttempt = _clock();
      await _prefs.setInt(_attemptKey, _lastAttempt!.millisecondsSinceEpoch);
      final latest = await _service.fetchLatestRelease();
      if (_disposed) return UpdateCheckResult.skipped;
      // A draft/prerelease response is not evidence that the installed app is latest.
      if (latest == null) throw const FormatException('No stable release');
      if (isNewerOfficialVersion(remoteVersion: latest.comparisonVersion,
          remoteBuild: latest.buildNumber, installedVersion: installed, installedBuild: installedBuild)) {
        final stored = await _prefs.setString(_cacheKey, jsonEncode({
          'tag': latest.tagName, 'page': latest.pageUri.toString(),
          'title': latest.title, 'notes': latest.notes,
          'ipa': latest.ipaUri?.toString(), 'sha256': latest.sha256Uri?.toString(),
          'hasSha256': latest.hasSha256, 'ipaSha256': latest.ipaSha256,
          'version': latest.comparisonVersion, 'build': latest.buildNumber,
        }));
        release = latest;
        if (!stored) throw StateError('Pending update cache was not persisted');
        return UpdateCheckResult.updateAvailable;
      }
      await _prefs.remove(_cacheKey);
      release = null;
      if (!automatic) message = '已是最新版（$installed）';
      return UpdateCheckResult.upToDate;
    } catch (error) {
      await AppLogger.write('update', 'check failed: $error');
      if (!automatic) message = appUpdateErrorMessage(error);
      return UpdateCheckResult.failed;
    } finally {
      checking = false;
      _notify();
    }
  }

  void _notify() { if (!_disposed) notifyListeners(); }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
