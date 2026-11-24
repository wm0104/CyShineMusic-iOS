import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/music_sources/music_source_controller.dart';
import '../../core/sdk/internal/sdk_http.dart';
import '../../core/storage/settings_store.dart';
import 'playlist_models.dart';

class SpotifyPlaylistPreview {
  const SpotifyPlaylistPreview({
    required this.id,
    required this.name,
    required this.tracks,
    this.total,
    this.creator,
    this.coverUrl,
    this.hasMatchingPlatforms = true,
  });

  final String id;
  final String name;
  final List<PlaylistTrack> tracks;
  final int? total;
  final String? creator;
  final String? coverUrl;
  final bool hasMatchingPlatforms;

  bool get complete => total == tracks.length;
  int get matched => tracks.where((track) => !track.isUnmatchedSpotify).length;
}

const _shareHosts = {
  'open.spotify.com',
  'spotify.link',
  'spotify.app.link',
  'spoti.fi',
};
bool _isSpotifyUrl(Uri uri) =>
    uri.scheme == 'https' &&
    !uri.hasPort &&
    uri.userInfo.isEmpty &&
    _shareHosts.contains(uri.host);

Uri? spotifyShareLink(String input) {
  final spotifyUri = RegExp(
    r'(?:^|\s)spotify:playlist:([a-zA-Z0-9]{22})(?![a-zA-Z0-9])',
  ).firstMatch(input);
  if (spotifyUri != null) {
    return Uri.https('open.spotify.com', '/playlist/${spotifyUri[1]}');
  }
  final urls = RegExp(
    r'''(?:https?://|(?:^|\s)(?=(?:open\.spotify\.com|spotify\.link|spotify\.app\.link|spoti\.fi)/))[^\s<>"'，。；）】]+''',
    caseSensitive: false,
  );
  for (final match in urls.allMatches(input)) {
    var text = match[0]!.trim().replaceFirst(RegExp(r'[\])},.!]+$'), '');
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri != null && _isSpotifyUrl(uri)) return uri;
  }
  return null;
}

String? _playlistId(Uri uri) {
  if (!_isSpotifyUrl(uri) || uri.host != 'open.spotify.com') return null;
  final match = RegExp(
    r'^/(?:intl-[a-zA-Z-]+/)?(?:embed/|user/[^/]+/)?playlist/([a-zA-Z0-9]{22})/?$',
  ).firstMatch(uri.path);
  return match?[1];
}

typedef SpotifyPageLoader =
    Future<({String body, Uri? redirect})> Function(Uri uri);
typedef SpotifyMusicSearch =
    Future<List<MusicInfo>> Function(String keyword, MusicSource source);

Future<({String body, Uri? redirect})> _loadPublicPage(Uri uri) async {
  final response = await SdkHttp.fetch<dynamic>(
    uri.toString(),
    responseType: ResponseType.plain,
    followRedirects: false,
    validateStatus: (status) => status != null && status >= 200 && status < 400,
  );
  final location = response.headers.value('location');
  return (
    body: response.body?.toString() ?? '',
    redirect: response.statusCode >= 300 && location != null
        ? uri.resolve(location)
        : null,
  );
}

class SpotifyPlaylistImporter {
  const SpotifyPlaylistImporter({
    this.loadPage = _loadPublicPage,
    required this.search,
    required this.enabledPlatforms,
  });

  final SpotifyPageLoader loadPage;
  final SpotifyMusicSearch search;
  final Future<List<MusicSource>> Function() enabledPlatforms;

  Future<SpotifyPlaylistPreview> read(
    Uri link, {
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    var target = link;
    for (var i = 0; i < 5 && _playlistId(target) == null; i++) {
      if (!_isSpotifyUrl(target) || target.host == 'open.spotify.com') break;
      final next = (await loadPage(target)).redirect;
      if (next == null) break;
      target = next;
    }
    final id = _playlistId(target);
    if (id == null) throw const FormatException('请输入 Spotify 公开歌单的分享链接');
    final totalRequest = _readTotal(id);
    final embed = await loadPage(
      Uri.https('open.spotify.com', '/embed/playlist/$id'),
    );
    final entity = _parseEntity(embed.body, id);
    final total = await totalRequest;
    final originals = _parseTracks(entity['trackList']);
    final platforms = await enabledPlatforms();
    final results = <PlaylistTrack>[
      for (final track in originals) PlaylistTrack.fromSpotify(track, null),
    ];
    var nextIndex = 0;
    var done = 0;
    onProgress?.call(done, results.length);
    Future<void> matchNext() async {
      while (nextIndex < results.length && cancelled?.call() != true) {
        final index = nextIndex++;
        final track = originals[index];
        if (track.type == 'track' && track.artist.isNotEmpty) {
          for (final platform in platforms) {
            if (cancelled?.call() == true) return;
            try {
              final candidates = await search(
                '${track.title} ${track.artist}',
                platform,
              );
              final match = _bestMatch(track, candidates, platform);
              if (match != null) {
                results[index] = PlaylistTrack.fromSpotify(track, match);
                break;
              }
            } on Exception {
              // A platform can fail independently of the other sources.
            }
          }
        }
        onProgress?.call(++done, results.length);
      }
    }

    await Future.wait(List.generate(3, (_) => matchNext()));
    final art = entity['coverArt'];
    final sources = art is Map ? art['sources'] : null;
    final cover = sources is List && sources.isNotEmpty ? sources.first : null;
    return SpotifyPlaylistPreview(
      id: id,
      name: entity['name'] as String,
      creator: entity['subtitle'] as String?,
      coverUrl: cover is Map ? cover['url'] as String? : null,
      total: total,
      hasMatchingPlatforms: platforms.isNotEmpty,
      tracks: List.unmodifiable(results),
    );
  }

  Future<int?> _readTotal(String id) async {
    try {
      final page = await loadPage(
        Uri.https('open.spotify.com', '/playlist/$id'),
      );
      for (final tag in RegExp(
        r'<meta\b[^>]*>',
        caseSensitive: false,
      ).allMatches(page.body)) {
        final html = tag[0]!;
        if (!RegExp(
          r'''(?:name|property)\s*=\s*["']music:song_count["']''',
          caseSensitive: false,
        ).hasMatch(html)) {
          continue;
        }
        final value = RegExp(
          r'''\bcontent\s*=\s*["'](\d+)["']''',
          caseSensitive: false,
        ).firstMatch(html);
        if (value != null) return int.tryParse(value[1]!);
      }
    } on Exception {
      // An embed may still be available; its length is never assumed to be the total.
    }
    return null;
  }
}

Map<String, dynamic> _parseEntity(String html, String id) {
  final script = RegExp(
    r'''<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>(.*?)</script\s*>''',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  Object? value = script == null ? null : jsonDecode(script[1]!);
  for (final key in ['props', 'pageProps', 'state', 'data', 'entity']) {
    value = value is Map ? value[key] : null;
  }
  if (value is! Map<String, dynamic> ||
      value['type'] != 'playlist' ||
      value['uri'] != 'spotify:playlist:$id' ||
      value['name'] is! String ||
      value['trackList'] is! List) {
    throw const FormatException('无法读取该 Spotify 公开歌单，请检查链接或稍后重试');
  }
  return value;
}

List<SpotifyTrackMetadata> _parseTracks(dynamic tracks) {
  final seen = <String, int>{};
  final entries = <SpotifyTrackMetadata>[];
  for (final value in tracks as List) {
    final row = value is Map ? value : const {};
    final title = row['title'] is String ? (row['title'] as String).trim() : '';
    final uri = row['uri'] as String? ?? 'unavailable:${entries.length}';
    final occurrence = seen[uri] ?? 0;
    seen[uri] = occurrence + 1;
    final type =
        row['entityType'] as String? ??
        (uri.startsWith('spotify:track:') ? 'track' : 'unknown');
    entries.add(
      SpotifyTrackMetadata(
        uri: uri,
        title: title.isEmpty ? '未公开曲名（第 ${entries.length + 1} 项）' : title,
        artist: (row['subtitle'] as String? ?? '').trim(),
        durationMs: (row['duration'] as num?)?.round(),
        explicit: row['isExplicit'] as bool?,
        type: title.isEmpty ? 'unknown' : type,
        occurrence: occurrence,
      ),
    );
  }
  return entries;
}

String _normalize(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

String _artists(String names) {
  final parts =
      names
          .split(
            RegExp(
              r'\s*(?:,|，|、|;|；|/|&|\sfeat[.]?\s|\sft[.]?\s)\s*',
              caseSensitive: false,
            ),
          )
          .map(_normalize)
          .where((name) => name.isNotEmpty)
          .toList()
        ..sort();
  return parts.join('|');
}

MusicInfo? _bestMatch(
  SpotifyTrackMetadata track,
  List<MusicInfo> candidates,
  MusicSource source,
) {
  final title = _normalize(track.title);
  final artist = _normalize(track.artist);
  if (title.isEmpty || artist.isEmpty) return null;
  MusicInfo? best;
  int? smallestDifference;
  var ambiguous = false;
  for (final candidate in candidates) {
    if (candidate.source != source ||
        candidate.id.isEmpty ||
        _normalize(candidate.name) != title ||
        (_normalize(candidate.singer) != artist &&
            _artists(candidate.singer) != _artists(track.artist))) {
      continue;
    }
    final parts = candidate.interval?.split(':').map(int.tryParse).toList();
    final int difference;
    if (track.durationMs != null && track.durationMs! > 0) {
      if (parts == null ||
          parts.length < 2 ||
          parts.length > 3 ||
          parts.contains(null)) {
        continue;
      }
      final ms = parts.fold<int>(0, (n, part) => n * 60 + part!) * 1000;
      difference = (ms - track.durationMs!).abs();
      if (difference > 4000) continue;
    } else {
      difference = 0;
    }
    if (smallestDifference == null || difference < smallestDifference) {
      best = candidate;
      smallestDifference = difference;
      ambiguous = false;
    } else if (difference == smallestDifference && candidate.id != best?.id) {
      ambiguous = true;
    }
  }
  return ambiguous ? null : best;
}

final spotifyPlaylistImporterProvider = Provider<SpotifyPlaylistImporter>((
  ref,
) {
  final api = ref.watch(musicApiProvider);
  final settings = ref.watch(settingsProvider);
  return SpotifyPlaylistImporter(
    search: (keyword, source) async => (await api.searchMusic(
      keyword: keyword,
      source: source,
      limit: 12,
    )).list,
    enabledPlatforms: () async {
      final state = await ref.read(musicSourceControllerProvider.future);
      return [
        for (final source in settings.discoverySourceOrder)
          if (settings.enabledSearchSources.contains(source) &&
              state.enabledFor(source).isNotEmpty)
            source,
      ];
    },
  );
});
