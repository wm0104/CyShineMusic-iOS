import 'dart:convert';

import 'package:cy_shine_music/core/services/app_update_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/ios_update_manifest_fixture.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<AppRelease?> fetch(IosManifestAdapter adapter) {
    final dio = iosManifestDio(adapter);
    addTearDown(dio.close);
    return AppUpdateService(dio: dio).fetchLatestRelease();
  }

  test('public manifest exposes its official IPA, digest and display version', () async {
    final adapter = IosManifestAdapter(iosManifest());
    final release = (await fetch(adapter))!;
    expect(adapter.requests, 1);
    expect(release.version.toString(), '2.0.9');
    expect(release.manifestVersion, '2.0.9');
    expect(release.comparisonVersion, '2.0.9');
    expect(release.buildNumber, 209);
    expect(release.displayVersion, '2.0.9 (209)');
    expect(release.tagName, 'ios-v2.0.9');
    expect(release.pageUri.toString(), releasePage);
    expect(release.title, 'CyShineMusic 2.0.9');
    expect(release.notes, '完善在线更新体验。');
    expect(release.ipaUri.toString(), ipaUrl);
    expect(release.ipaSha256, List.filled(64, 'b').join());
    expect(trollStoreInstallUri(release.ipaUri!).queryParameters['url'], ipaUrl);
    expect(trollStoreInstallUri(release.ipaUri!).toString(),
        'apple-magnifier://install?url=https%3A%2F%2Fgithub.com%2Fwm0104%2FCyShineMusic-iOS%2Freleases%2Fdownload%2Fios-v2.0.9%2FCyShineMusic-unsigned.ipa');
  });

  test('missing IPA still exposes the release page without an install URL', () async {
    final release = (await fetch(IosManifestAdapter(iosManifest()..remove('ipa'))))!;
    expect(release.pageUri.toString(), releasePage);
    expect(release.ipaUri, isNull);
    expect(release.ipaSha256, isNull);
  });

  test('four components and matching numeric metadata retain display precision', () async {
    final data = iosManifest()
      ..['version'] = '2.0.9.1+209'
      ..['tag'] = 'ios-v2.0.9.1+209'
      ..['page_url'] = releasePage.replaceAll('ios-v2.0.9', 'ios-v2.0.9.1+209')
      ..remove('ipa');
    final release = (await fetch(IosManifestAdapter(data)))!;
    expect(release.version.toString(), '2.0.9');
    expect(release.manifestVersion, '2.0.9.1+209');
    expect(release.comparisonVersion, '2.0.9.1+209');
    expect(release.displayVersion, '2.0.9.1 (209)');
  });

  test('nonnumeric metadata retains the explicit manifest build', () async {
    final release = (await fetch(IosManifestAdapter(iosManifest()..['version'] = '2.0.9+release')))!;
    expect(release.manifestVersion, '2.0.9+release');
    expect(release.buildNumber, 209);
    expect(release.displayVersion, '2.0.9 (209)');
  });

  test('optional descriptions and uppercase SHA256 are accepted', () async {
    final data = iosManifest()..remove('name')..remove('notes');
    (data['ipa'] as Map<String, Object?>)['sha256'] = List.filled(64, 'A').join();
    final release = (await fetch(IosManifestAdapter(data)))!;
    expect(release.title, '2.0.9');
    expect(release.notes, '');
    expect(release.ipaSha256, List.filled(64, 'a').join());
  });

  test('empty title falls back to version and notes are capped at 16384', () async {
    final data = iosManifest()..['name'] = ''..['notes'] = List.filled(17000, 'n').join();
    final release = (await fetch(IosManifestAdapter(data)))!;
    expect(release.title, '2.0.9');
    expect(release.notes, List.filled(16384, 'n').join());
  });

  for (final host in ['github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com']) {
    test('accepts final HTTPS response on $host without REST fallback', () async {
      final adapter = IosManifestAdapter(iosManifest(), finalUrl: 'https://$host/asset?signature=public');
      expect(await fetch(adapter), isNotNull);
      expect(adapter.requests, 1);
    });
  }
  for (final url in [
    'http://release-assets.githubusercontent.com/asset',
    'https://evil.example/asset',
    'https://release-assets.githubusercontent.com.evil.example/asset',
    'https://user@objects.githubusercontent.com/asset',
    'https://objects.githubusercontent.com:444/asset',
    'https://objects.githubusercontent.com/asset#fragment',
  ]) {
    test('rejects untrusted final response $url', () async {
      await expectLater(fetch(IosManifestAdapter(iosManifest(), finalUrl: url)), throwsFormatException);
    });
  }

  final invalidFields = <String, List<Object?>>{
    'schema': [null, '1', 2],
    'repository': [null, 1, 'KevinllBin/CyShineMusic'],
    'version': [null, 209, '2.0', '2.0.9-beta.1', '2.0.9+210', '2.0.8'],
    'tag': [null, 209, 'ios-v2.0.9-beta.1', 'ios-v2.0.9+210', 'ios-v2.0.8'],
    'build': [null, '209', 209.5, 0, -1, true],
    'source_commit': [null, 40, 'abc', List.filled(40, 'g').join()],
    'name': [42, [], {}],
    'notes': [42, [], {}],
    'ipa': [42, [], {'name': 'other.ipa'}, {}],
  };
  for (final field in invalidFields.entries) {
    for (var i = 0; i < field.value.length; i++) {
      test('rejects malformed manifest ${field.key} case $i', () async {
        final data = iosManifest()..[field.key] = field.value[i];
        await expectLater(fetch(IosManifestAdapter(data)), throwsFormatException);
      });
    }
  }
  for (final data in <Object?>[null, [], 'not an object']) {
    test('rejects non-object manifest $data', () async {
      await expectLater(fetch(IosManifestAdapter(data)), throwsFormatException);
    });
  }

  for (final page in [
    releasePage.replaceFirst('https:', 'http:'),
    releasePage.replaceFirst('github.com', 'evil.example'),
    releasePage.replaceFirst('github.com', 'github.com.evil.example'),
    releasePage.replaceFirst('github.com', 'user@github.com'),
    releasePage.replaceFirst('github.com', 'github.com:444'),
    '$releasePage?evil=1', '$releasePage#fragment',
    releasePage.replaceFirst('ios-v2.0.9', 'ios-v2.0.8'),
    'https://github.com/wm0104/CyShineMusic-iOS/releases/latest',
  ]) {
    test('rejects inconsistent or decorated release page $page', () async {
      await expectLater(fetch(IosManifestAdapter(iosManifest()..['page_url'] = page)), throwsFormatException);
    });
  }

  for (final url in [
    ipaUrl.replaceFirst('https:', 'http:'),
    ipaUrl.replaceFirst('github.com', 'evil.example'),
    ipaUrl.replaceFirst('github.com', 'github.com.evil.example'),
    ipaUrl.replaceFirst('github.com', 'user@github.com'),
    ipaUrl.replaceFirst('github.com', 'github.com:444'),
    ipaUrl.replaceFirst('wm0104', 'KevinllBin'),
    ipaUrl.replaceFirst('ios-v2.0.9', 'ios-v2.0.8'),
    ipaUrl.replaceFirst('CyShineMusic-unsigned.ipa', 'other.ipa'),
    ipaUrl.replaceFirst('CyShineMusic-unsigned.ipa', '%2Fother.ipa'),
    ipaUrl.replaceFirst('CyShineMusic-unsigned.ipa', '%252Fother.ipa'),
    '$ipaUrl?token=secret', '$ipaUrl#fragment',
  ]) {
    test('rejects malicious IPA URL and TrollStore installation $url', () async {
      final data = iosManifest();
      (data['ipa'] as Map<String, Object?>)['url'] = url;
      await expectLater(fetch(IosManifestAdapter(data)), throwsFormatException);
      // The standalone installer allows any official tag, but not foreign URLs.
      if (!url.contains('ios-v2.0.8')) {
        expect(() => trollStoreInstallUri(Uri.parse(url)), throwsArgumentError);
      }
    });
  }
  for (final field in ['name', 'url', 'sha256']) {
    for (final value in <Object?>[null, 12, 'invalid']) {
      test('rejects invalid IPA $field=$value', () async {
        final data = iosManifest();
        (data['ipa'] as Map<String, Object?>)[field] = value;
        await expectLater(fetch(IosManifestAdapter(data)), throwsFormatException);
      });
    }
  }

  test('stream rejects over 128 KiB even without a content-length header', () async {
    final adapter = IosManifestAdapter(null, chunks: [
      List.filled(128 * 1024, 32), [32],
    ]);
    await expectLater(fetch(adapter), throwsFormatException);
    expect(adapter.requests, 1);
  });
  test('exactly 128 KiB of streamed JSON is accepted', () async {
    final encoded = utf8.encode(jsonEncode(iosManifest()));
    final adapter = IosManifestAdapter(null, chunks: [
      encoded, List.filled(128 * 1024 - encoded.length, 32),
    ]);
    expect(await fetch(adapter), isNotNull);
  });
  test('invalid JSON is not treated as an up-to-date release', () async {
    await expectLater(fetch(IosManifestAdapter(null, chunks: [utf8.encode('{')])), throwsFormatException);
  });
  test('every repeated check requests fresh metadata without credentials', () async {
    final adapter = IosManifestAdapter(iosManifest());
    final dio = iosManifestDio(adapter);
    addTearDown(dio.close);
    final service = AppUpdateService(dio: dio);
    await service.fetchLatestRelease();
    await service.fetchLatestRelease();
    expect(adapter.requests, 2);
  });
  for (final status in [302, 401, 403, 404, 429, 500]) {
    test('HTTP $status preserves status, body and headers without REST fallback', () async {
      final adapter = IosManifestAdapter({'message': 'Not ready'}, status: status,
          headers: {'retry-after': ['60']});
      await expectLater(fetch(adapter), throwsA(isA<DioException>()
          .having((e) => e.type, 'type', DioExceptionType.badResponse)
          .having((e) => e.response?.statusCode, 'status', status)
          .having((e) => e.response?.data, 'body', jsonEncode({'message': 'Not ready'}))
          .having((e) => e.response?.headers.value('retry-after'), 'header', '60')));
      expect(adapter.requests, 1);
    });
  }

  test('403 without rate-limit evidence means denied, not frequent requests', () async {
    try {
      await fetch(IosManifestAdapter({'message': 'Forbidden'}, status: 403));
      fail('403 must throw');
    } on DioException catch (error) {
      expect(appUpdateErrorMessage(error), contains('拒绝访问'));
      expect(appUpdateErrorMessage(error), isNot(contains('频繁')));
      expect(appUpdateErrorMessage(error), isNot(contains('额度')));
    }
  });
  for (final evidence in [
    <String, Object?>{'headers': {'x-ratelimit-remaining': ['0']}},
    <String, Object?>{'body': {'message': 'API rate limit exceeded for public IP'}},
  ]) {
    test('403 with primary rate-limit evidence reports exhausted quota: $evidence', () async {
      try {
        await fetch(IosManifestAdapter(evidence['body'] ?? {'message': 'Forbidden'},
            status: 403, headers: evidence['headers'] as Map<String, List<String>>? ?? {}));
        fail('403 must throw');
      } on DioException catch (error) {
        expect(appUpdateErrorMessage(error), contains('额度已用尽'));
      }
    });
  }
  test('primary limit reset header supplies a retry clock', () {
    final error = _error(403, headers: {
      'x-ratelimit-remaining': ['0'], 'x-ratelimit-reset': ['2000000000'],
    });
    expect(appUpdateErrorMessage(error), contains('预计'));
    expect(appUpdateErrorMessage(error), contains('后可重试'));
  });
  test('remaining quota alone is not evidence of primary rate limiting', () {
    expect(appUpdateErrorMessage(_error(403, headers: {'x-ratelimit-remaining': ['10']})), contains('拒绝访问'));
  });
  for (final status in [403, 429]) {
    test('$status retry-after reports seconds, secondary limit reports temporary restriction', () {
      expect(appUpdateErrorMessage(_error(status, headers: {'retry-after': ['45']})), contains('45 秒'));
      expect(appUpdateErrorMessage(_error(status, body: '{"message":"secondary rate limit"}')), contains('暂时受限'));
      expect(appUpdateErrorMessage(_error(status, body: {'message': 'abuse detection'})), contains('暂时受限'));
    });
  }
  test('429 without evidence is frequent; 404 means metadata not ready', () {
    expect(appUpdateErrorMessage(_error(429)), contains('频繁'));
    expect(appUpdateErrorMessage(_error(404)), contains('尚未就绪'));
    expect(appUpdateErrorMessage(_error(401)), contains('无法访问'));
    expect(appUpdateErrorMessage(const FormatException()), contains('数据无效'));
    expect(appUpdateErrorMessage(_error(500)), contains('网络连接失败'));
  });
  for (final type in [DioExceptionType.connectionTimeout, DioExceptionType.receiveTimeout,
    DioExceptionType.sendTimeout, DioExceptionType.badCertificate]) {
    test('transport $type retains timeout or TLS classification', () async {
      try {
        await fetch(IosManifestAdapter(null, errorType: type));
        fail('transport error must throw');
      } on DioException catch (error) {
        expect(error.type, type);
        expect(appUpdateErrorMessage(error), contains(type == DioExceptionType.badCertificate ? '安全连接失败' : '超时'));
      }
    });
  }
}

DioException _error(int status, {Object? body, Map<String, List<String>> headers = const {}}) {
  final options = RequestOptions(path: manifestUrl);
  return DioException(requestOptions: options, type: DioExceptionType.badResponse,
      response: Response<Object?>(requestOptions: options, statusCode: status,
          data: body, headers: Headers.fromMap(headers)));
}
