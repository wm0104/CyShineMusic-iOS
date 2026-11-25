import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cy_shine_music/core/models/enums.dart';
import 'package:cy_shine_music/core/models/music_info.dart';
import 'package:cy_shine_music/core/music_sources/music_source_models.dart';
import 'package:cy_shine_music/core/music_sources/music_source_playback_policy.dart';
import 'package:cy_shine_music/core/music_sources/music_source_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('load sends separate policy without rewriting metadata or source JS', () async {
    const script = '/** @name Original source */\n(function () {})();';
    for (final channelName in ['test/playback-policy', 'test/update-policy']) {
      final channel = MethodChannel(channelName);
      final calls = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'load' ? <String, dynamic>{'sources': {}} : null;
      });
      final runtime = MusicSourceRuntime(Dio(), channel: channel);
      try {
        await runtime.load(_record(), script);
        final arguments = calls.single.arguments as Map;
        expect(arguments['script'], script);
        expect(arguments['playbackPolicyScript'], musicSourcePlaybackPolicyScript);
        expect(arguments['sourceKey'], _record().runtimeKey);
        expect(arguments['name'], 'Original source');
      } finally {
        await runtime.disposeRuntime();
        messenger.setMockMethodCallHandler(channel, null);
      }
    }
  });

  test('concurrent wy and tx resolves preserve platform IDs after a failed request', () async {
    const channel = MethodChannel('test/playback-policy-requests');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final resolveCalls = <Map<dynamic, dynamic>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') return <String, dynamic>{'sources': {}};
      if (call.method != 'resolve') return null;
      resolveCalls.add(call.arguments as Map);
      if (resolveCalls.length == 1) {
        firstStarted.complete();
        await releaseFirst.future;
        throw PlatformException(code: 'RESOLVE_FAILED', message: 'offline failure');
      }
      return <String, dynamic>{'url': 'https://offline.invalid/result'};
    });
    final runtime = MusicSourceRuntime(Dio(), channel: channel);
    try {
      final wy = runtime.resolveWithSource(
        record: _record(), script: '/* unchanged */',
        music: _music('wy', 'wy-original-id'), quality: Quality.flac,
      );
      final failure = expectLater(wy, throwsA(isA<MusicSourceRuntimeException>()));
      await firstStarted.future;
      final tx = runtime.resolveWithSource(
        record: _record(), script: '/* unchanged */',
        music: _music('tx', 'tx-original-id'), quality: Quality.k320,
      );
      await Future<void>.delayed(Duration.zero);
      expect(resolveCalls, hasLength(1));
      releaseFirst.complete();
      await failure;
      await tx;
      expect(resolveCalls, hasLength(2));
      for (final (index, source, id, quality) in [
        (0, 'wy', 'wy-original-id', 'flac'),
        (1, 'tx', 'tx-original-id', '320k'),
      ]) {
        final call = resolveCalls[index];
        final musicInfo = call['musicInfo'] as Map;
        expect(call['source'], source);
        expect(call['quality'], quality);
        expect(musicInfo['source'], source);
        expect(musicInfo['songmid'], id);
        expect(musicInfo['name'], 'same title');
        expect(musicInfo['singer'], 'same singer');
      }
    } finally {
      await runtime.disposeRuntime();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}

MusicSourceRecord _record() => MusicSourceRecord(
  id: 'policy-test', name: 'Original source', description: '', author: '',
  homepage: '', version: '1', origin: 'offline',
  importedAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0), capabilities: const {},
);

MusicInfo _music(String source, String songId) => MusicInfo.fromJson({
  'id': '$source-$songId', 'name': 'same title', 'singer': 'same singer',
  'source': source, 'meta': {'songId': songId, 'albumName': 'fixture', 'qualitys': []},
});
