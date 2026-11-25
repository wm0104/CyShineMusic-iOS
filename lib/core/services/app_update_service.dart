import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/dio_factory.dart';
import '../storage/settings_store.dart';
import 'app_update_version.dart';

const _githubApiBaseUrl = 'https://api.github.com';

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tagName,
    required this.pageUri,
    required this.title,
    this.notes = '',
    this.ipaUri,
    this.sha256Uri,
    this.hasSha256 = false,
    this.buildNumber,
    this.manifestVersion,
    this.ipaSha256,
  });

  final Version version;
  final String tagName;
  final Uri pageUri;
  final String title;
  final String notes;
  final Uri? ipaUri;
  final Uri? sha256Uri;
  final bool hasSha256;
  final int? buildNumber;
  final String? manifestVersion;
  final String? ipaSha256;

  String get comparisonVersion => manifestVersion ?? tagName;
  String get versionLabel => OfficialAppVersion.tryParse(comparisonVersion)?.core ?? version.toString();
  String get displayVersion => buildNumber == null ? versionLabel : '$versionLabel ($buildNumber)';
}

class AppUpdateService {
  AppUpdateService({required Dio dio}) : _dio = dio;

  final Dio _dio;

  Future<AppRelease?> fetchLatestRelease() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) return _fetchIosManifest();
    const repository = 'KevinllBin/CyShineMusic';
    final response = await _dio.get<Object?>('/repos/$repository/releases/latest');
    final data = response.data;
    if (data is! Map) {
      throw const FormatException('GitHub release response is not an object');
    }
    if (data['draft'] == true || data['prerelease'] == true) return null;
    final tagName = data['tag_name']?.toString().trim() ?? '';
    final version = parseAppVersion(tagName);
    final pageUri = Uri.tryParse(data['html_url']?.toString().trim() ?? '');
    if (version == null || !_isGithubReleaseUri(pageUri, repository)) {
      throw const FormatException('GitHub release fields are invalid');
    }
    final name = data['name']?.toString().trim();
    return AppRelease(version: version, tagName: tagName, pageUri: pageUri!,
      title: name == null || name.isEmpty ? tagName : name);
  }

  Future<AppRelease> _fetchIosManifest() async {
    final token = CancelToken();
    final response = await _dio.get<ResponseBody>(iosUpdateManifestUrl,
      cancelToken: token,
      options: Options(responseType: ResponseType.stream, followRedirects: true,
        maxRedirects: 5, receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30), validateStatus: (_) => true,
        headers: {'Accept': 'application/json', 'Cache-Control': 'no-cache'}),
    );
    if (!isTrustedUpdateResponseUri(response.realUri)) {
      token.cancel('Untrusted update metadata redirect');
      throw const FormatException('Untrusted update metadata host');
    }
    final bytes = <int>[];
    final body = response.data;
    if (body == null) throw const FormatException('Empty update metadata');
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > 128 * 1024) {
        token.cancel('Update metadata exceeds size limit');
        throw const FormatException('Update metadata exceeds size limit');
      }
      bytes.addAll(chunk);
    }
    final text = utf8.decode(bytes, allowMalformed: response.statusCode != 200);
    if (response.statusCode != 200) {
      throw DioException(requestOptions: response.requestOptions,
        response: Response<String>(requestOptions: response.requestOptions,
          data: text, statusCode: response.statusCode, headers: response.headers),
        type: DioExceptionType.badResponse);
    }
    return parseOfficialUpdateManifest(text);
  }
}

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  final adapterMode = ref.watch(
    settingsProvider.select((settings) => settings.networkAdapterMode),
  );
  final dio = _createGithubDio(adapterMode: adapterMode);
  ref.onDispose(dio.close);
  return AppUpdateService(dio: dio);
});

typedef ExternalUriLauncher = Future<bool> Function(Uri uri);

final externalUriLauncherProvider = Provider<ExternalUriLauncher>((ref) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});

Version? parseAppVersion(String value) {
  final normalized = value
      .trim()
      .replaceFirst(RegExp(r'^(?:ios-)?v', caseSensitive: false), '')
      .split('+')
      .first;
  if (normalized.isEmpty) return null;
  try {
    return Version.parse(normalized);
  } on FormatException {
    return null;
  }
}

bool isNewerAppVersion({
  required String currentVersion,
  required String latestVersion,
}) {
  final current = parseAppVersion(currentVersion);
  final latest = parseAppVersion(latestVersion);
  return current != null && latest != null && latest > current;
}

Dio _createGithubDio({NetworkAdapterMode? adapterMode}) {
  return createDio(
    BaseOptions(
      baseUrl: _githubApiBaseUrl,
      connectTimeout: Duration(seconds: defaultTargetPlatform == TargetPlatform.iOS ? 30 : 5),
      receiveTimeout: Duration(seconds: defaultTargetPlatform == TargetPlatform.iOS ? 30 : 8),
      sendTimeout: Duration(seconds: defaultTargetPlatform == TargetPlatform.iOS ? 30 : 5),
      responseType: ResponseType.json,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'CyShineMusic',
      },
    ),
    adapterMode: adapterMode,
  );
}

bool _isGithubReleaseUri(Uri? uri, String repository) {
  if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
    return false;
  }
  return uri.path.startsWith('/$repository/releases/');
}

const iosUpdateRepository = 'wm0104/CyShineMusic-iOS';
const iosUpdateIpaName = 'CyShineMusic-unsigned.ipa';
const iosUpdateManifestUrl = 'https://github.com/$iosUpdateRepository/releases/latest/download/ios-update.json';

bool isTrustedUpdateResponseUri(Uri uri) => uri.scheme == 'https' &&
    uri.userInfo.isEmpty && !uri.hasPort && uri.fragment.isEmpty &&
    const {'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}
        .contains(uri.host);

AppRelease parseOfficialUpdateManifest(String text) {
  final data = jsonDecode(text);
  if (data is! Map || data['schema'] is! int || data['schema'] != 1 || data['repository'] != iosUpdateRepository ||
      data['version'] is! String || data['tag'] is! String || data['build'] is! int ||
      (data['build'] as int) <= 0 || data['page_url'] is! String ||
      data['source_commit'] is! String) {
    throw const FormatException('Invalid official update metadata');
  }
  final versionText = data['version'] as String;
  final tag = data['tag'] as String;
  final parsed = OfficialAppVersion.tryParse(versionText);
  final parsedTag = OfficialAppVersion.tryParse(tag);
  final build = data['build'] as int;
  final commit = data['source_commit'] as String;
  final page = Uri.tryParse(data['page_url'] as String);
  if (parsed == null || parsedTag == null || parsed.isPrerelease || parsedTag.isPrerelease ||
      parsed.core != parsedTag.core || (parsed.build != null && parsed.build != build) ||
      (parsedTag.build != null && parsedTag.build != build) ||
      commit.length != 40 || !RegExp(r'^[a-f0-9]+$').hasMatch(commit) ||
      !isOfficialUpdateReleaseUri(page, tag)) {
    throw const FormatException('Inconsistent official release metadata');
  }
  Uri? ipaUri;
  String? digest;
  final ipa = data['ipa'];
  if (ipa != null) {
    if (ipa is! Map || ipa['name'] != iosUpdateIpaName ||
        ipa['url'] is! String || ipa['sha256'] is! String) {
      throw const FormatException('Invalid official IPA metadata');
    }
    ipaUri = Uri.tryParse(ipa['url'] as String);
    digest = ipa['sha256'] as String;
    if (!isOfficialUpdateAssetUri(ipaUri, tagName: tag) || digest.length != 64 ||
        !RegExp(r'^[a-fA-F0-9]+$').hasMatch(digest)) {
      throw const FormatException('Untrusted official IPA metadata');
    }
    digest = digest.toLowerCase();
  }
  final notes = data['notes'];
  final name = data['name'];
  if ((notes != null && notes is! String) || (name != null && name is! String)) {
    throw const FormatException('Invalid official release description');
  }
  final description = (notes as String? ?? '').trim();
  return AppRelease(
    version: Version(parsed.components[0], parsed.components[1], parsed.components[2]),
    manifestVersion: versionText, buildNumber: build, tagName: tag, pageUri: page!,
    title: name is String && name.trim().isNotEmpty ? name.trim() : parsed.core,
    notes: description.length > 16384 ? description.substring(0, 16384) : description,
    ipaUri: ipaUri, ipaSha256: digest,
  );
}

bool isOfficialUpdateAssetUri(Uri? uri, {String? tagName, String? fileName}) {
  if (uri == null || uri.scheme != 'https' || uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty || uri.hasPort || uri.hasQuery || uri.hasFragment) {
    return false;
  }
  final parts = uri.pathSegments;
  return parts.length == 6 &&
      parts.take(4).join('/') == '$iosUpdateRepository/releases/download' &&
      OfficialAppVersion.tryParse(parts[4])?.isPrerelease == false &&
      (tagName == null || parts[4] == tagName) &&
      (fileName == null
          ? parts[5] == iosUpdateIpaName
          : parts[5] == fileName);
}

Uri trollStoreInstallUri(Uri ipaUri) {
  if (!isOfficialUpdateAssetUri(ipaUri)) {
    throw ArgumentError('Untrusted official IPA URL');
  }
  return Uri.parse('apple-magnifier://install?url=${Uri.encodeComponent(ipaUri.toString())}');
}

String appUpdateErrorMessage(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    String? header(String name) => error.response?.headers.value(name);
    final data = error.response?.data;
    var reason = data is Map ? data['message']?.toString() ?? '' : data is String ? data : '';
    if (data is String) {
      try {
        final json = jsonDecode(data);
        if (json is Map) reason = json['message']?.toString() ?? reason;
      } on FormatException { /* An HTTP error may be HTML rather than JSON. */ }
    }
    reason = reason.toLowerCase();
    if (status == 403 || status == 429) {
      if (header('x-ratelimit-remaining') == '0' || reason.contains('api rate limit exceeded')) {
        final reset = int.tryParse(header('x-ratelimit-reset') ?? '');
        if (reset != null && reset > 0 && reset < 253402300799) {
          final time = DateTime.fromMillisecondsSinceEpoch(reset * 1000).toLocal();
          final clock = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
          return 'GitHub 请求额度已用尽，预计 $clock 后可重试';
        }
        return 'GitHub 请求额度已用尽，请稍后重试';
      }
      final retry = int.tryParse(header('retry-after') ?? '');
      if (retry != null || reason.contains('secondary rate limit') || reason.contains('abuse')) {
        return retry != null && retry > 0
            ? 'GitHub 请求暂时受限，请等待 $retry 秒后重试'
            : 'GitHub 请求暂时受限，请稍后重试';
      }
      return status == 429 ? '请求过于频繁，请稍后重试' : 'GitHub 拒绝访问更新信息，请稍后重试或查看官方发行版';
    }
    if (status == 404) return '更新信息尚未就绪，请稍后重试或查看官方发行版';
    if (status == 401) return '更新信息无法访问，请查看官方发行版';
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) return '连接超时，请稍后重试';
    if (error.type == DioExceptionType.badCertificate) return '安全连接失败，请检查系统时间后重试';
    return '网络连接失败，请稍后重试';
  }
  if (error is FormatException) return '发行版数据无效，请查看官方发行页';
  return '检查更新失败，请稍后重试';
}

bool isOfficialUpdateReleaseUri(Uri? uri, String tagName) =>
    uri != null && uri.scheme == 'https' && uri.host == 'github.com' &&
    uri.userInfo.isEmpty && !uri.hasPort && !uri.hasQuery && !uri.hasFragment &&
    uri.path == '/$iosUpdateRepository/releases/tag/$tagName';
