import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cy_shine_music/core/api/music_api.dart';
import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/search_response.dart';
import 'package:cy_shine_music/core/storage/settings_store.dart';
import 'package:cy_shine_music/features/search/search_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'enabled_search_source_codes': ['kw', 'wy'],
      'network_adapter_mode': 'io',
    }),
  );

  test(
    'aggregate search retries failed providers and caches complete pages',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(switch (request.uri.path) {
            '/r.s' => {
              'abslist': [
                if (request.uri.queryParameters['all'] != 'empty')
                  {
                    'MUSICRID': 'MUSIC_123',
                    'SONGNAME': 'Recovered song',
                    'ARTIST': 'Singer',
                    'N_MINFO': '',
                  },
              ],
            },
            '/eapi/batch' => {
              'code': 200,
              'data': {'resources': []},
            },
            _ => throw StateError(
              'Unexpected search request ${request.uri.path}',
            ),
          }),
        );
        await request.response.close();
      });
      final client = _SearchHttpClient(server.port);
      addTearDown(() => client.close(force: true));
      final container = await _searchContainer();
      final controller = container.read(searchControllerProvider.notifier);

      await HttpOverrides.runZoned(() async {
        await controller.search(keyword: 'song', source: MusicSource.all);
        expect(client.requests, hasLength(2));
        expect(container.read(searchControllerProvider).loading, isFalse);
        expect(container.read(searchControllerProvider).error, '无法连接到服务器');

        client.failedHosts.remove('search.kuwo.cn');
        await controller.search(keyword: 'song');
        expect(client.requests, hasLength(4));
        expect(container.read(searchControllerProvider).error, isNull);
        expect(
          container.read(searchControllerProvider).response!.list.single.id,
          'kw_123',
        );

        client.failedHosts.clear();
        await controller.search(keyword: 'song');
        expect(client.requests, hasLength(6));
        await controller.search(keyword: 'song');
        expect(client.requests, hasLength(6));

        await controller.search(keyword: 'empty');
        expect(
          container.read(searchControllerProvider).response!.list,
          isEmpty,
        );
        expect(container.read(searchControllerProvider).error, isNull);
        await controller.search(keyword: 'empty');
        expect(client.requests, hasLength(8));

        await container
            .read(settingsProvider.notifier)
            .setSearchSourceEnabled(MusicSource.wy, false);
        await container.pump();
        await controller.search(keyword: 'empty');
        expect(client.requests.skip(8).map((uri) => uri.host), [
          'search.kuwo.cn',
        ]);
      }, createHttpClient: (_) => client);
    },
  );

  test('changing source order lets a single-source search finish', () async {
    final api = _PendingSearchApi();
    final container = await _searchContainer(api: api);
    final controller = container.read(searchControllerProvider.notifier);
    final pending = controller.search(keyword: 'song', source: MusicSource.kw);
    expect(container.read(searchControllerProvider).loading, isTrue);

    await container.read(settingsProvider.notifier).setDiscoverySourceOrder([
      MusicSource.kw,
      MusicSource.wy,
    ]);
    api.requests.single.complete(_response(MusicSource.kw));
    await pending;
    expect(container.read(searchControllerProvider).loading, isFalse);
    expect(
      container.read(searchControllerProvider).response?.source,
      MusicSource.kw,
    );
  });

  test(
    'old aggregate work cannot replace or cache results after disabling a source',
    () async {
      final api = _PendingSearchApi();
      final container = await _searchContainer(api: api);
      final controller = container.read(searchControllerProvider.notifier);
      final pending = controller.search(
        keyword: 'song',
        source: MusicSource.all,
      );
      await container
          .read(settingsProvider.notifier)
          .setSearchSourceEnabled(MusicSource.wy, false);
      await container.pump();

      expect(api.requests, hasLength(2));
      final currentResult = _response(MusicSource.kw);
      api.requests.last.complete(currentResult);
      await container.pump();
      expect(
        container.read(searchControllerProvider).response,
        same(currentResult),
      );

      api.requests.first.complete(_response(MusicSource.wy));
      await pending;
      await controller.search(keyword: 'song');
      expect(api.requests, hasLength(2));
      expect(
        container.read(searchControllerProvider).response,
        same(currentResult),
      );
    },
  );
}

Future<ProviderContainer> _searchContainer({_PendingSearchApi? api}) async {
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      if (api != null) musicApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

SearchResponse _response(MusicSource source) => SearchResponse(
  list: const [],
  page: 1,
  limit: 30,
  allPage: 1,
  total: 0,
  source: source,
);

class _PendingSearchApi extends MusicApi {
  final requests = <Completer<SearchResponse>>[];

  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) {
    final response = Completer<SearchResponse>();
    requests.add(response);
    return response.future;
  }
}

class _RealHttpOverrides extends HttpOverrides {}

class _SearchHttpClient implements HttpClient {
  _SearchHttpClient(this.port);

  final int port;
  final _delegate = _RealHttpOverrides().createHttpClient(null);
  final requests = <Uri>[];
  final failedHosts = {'search.kuwo.cn', 'interface.music.163.com'};

  @override
  set idleTimeout(Duration value) => _delegate.idleTimeout = value;

  @override
  set connectionTimeout(Duration? value) => _delegate.connectionTimeout = value;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add(url);
    if (failedHosts.contains(url.host)) throw const SocketException('offline');
    return _delegate.openUrl(
      method,
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
