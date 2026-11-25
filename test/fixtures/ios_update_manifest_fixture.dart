import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const manifestUrl = 'https://github.com/wm0104/CyShineMusic-iOS/releases/latest/download/ios-update.json';
const releasePage = 'https://github.com/wm0104/CyShineMusic-iOS/releases/tag/ios-v2.0.9';
const ipaUrl = 'https://github.com/wm0104/CyShineMusic-iOS/releases/download/ios-v2.0.9/CyShineMusic-unsigned.ipa';

Map<String, Object?> iosManifest() => {
  'schema': 1,
  'repository': 'wm0104/CyShineMusic-iOS',
  'version': '2.0.9',
  'build': 209,
  'tag': 'ios-v2.0.9',
  'page_url': releasePage,
  'source_commit': List.filled(40, 'a').join(),
  'name': 'CyShineMusic 2.0.9',
  'notes': '完善在线更新体验。',
  'ipa': <String, Object?>{
    'name': 'CyShineMusic-unsigned.ipa',
    'url': ipaUrl,
    'sha256': List.filled(64, 'b').join(),
  },
};

class IosManifestAdapter implements HttpClientAdapter {
  IosManifestAdapter(this.data, {
    this.status = 200,
    this.finalUrl,
    this.headers = const {},
    this.chunks,
    this.errorType,
  });

  final Object? data;
  final int status;
  final String? finalUrl;
  final Map<String, List<String>> headers;
  final List<List<int>>? chunks;
  final DioExceptionType? errorType;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    requests++;
    expect(options.uri.toString(), manifestUrl);
    expect(options.responseType, ResponseType.stream);
    expect(options.followRedirects, isTrue);
    expect(options.maxRedirects, 5);
    expect(options.receiveTimeout, const Duration(seconds: 30));
    expect(options.sendTimeout, const Duration(seconds: 30));
    final requestHeaders = options.headers.map((key, value) => MapEntry(key.toLowerCase(), value));
    expect(requestHeaders['cache-control'], 'no-cache');
    expect(requestHeaders['accept'], 'application/json');
    for (final credential in ['authorization', 'proxy-authorization', 'cookie', 'x-github-token']) {
      expect(requestHeaders.containsKey(credential), isFalse);
    }
    if (errorType != null) {
      throw DioException(requestOptions: options, type: errorType!);
    }
    return ResponseBody(
      Stream<Uint8List>.fromIterable((chunks ?? [utf8.encode(jsonEncode(data))])
          .map((chunk) => Uint8List.fromList(chunk))),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType], ...headers},
      redirects: finalUrl == null ? [] : [RedirectRecord(302, 'GET', Uri.parse(finalUrl!))],
      isRedirect: finalUrl != null,
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio iosManifestDio(IosManifestAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://api.github.com'))..httpClientAdapter = adapter;
