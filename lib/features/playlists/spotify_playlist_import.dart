import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/music_api.dart';
import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../../core/music_sources/music_source_controller.dart';
import '../../core/sdk/internal/sdk_http.dart';
import '../../core/sdk/wy_sdk.dart' show WySearchException;
import '../../core/services/app_logger.dart';
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
    this.matchIssues,
  });

  final String id;
  final String name;
  final List<PlaylistTrack> tracks;
  final int? total;
  final String? creator;
  final String? coverUrl;
  final bool hasMatchingPlatforms;
  final SpotifyMatchIssues? matchIssues;

  bool get complete => total == tracks.length;
  int get matched => tracks.where((track) => !track.isUnmatchedSpotify).length;
}

class SpotifyMatchIssues {
  const SpotifyMatchIssues({
    required this.failed,
    required this.unfinished,
    required this.rateLimited,
  });

  final int failed;
  final int unfinished;
  final bool rateLimited;
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
    MusicSource source = MusicSource.wy,
    Iterable<PlaylistTrack> Function(String id)? existingMatches,
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
    final originals = _parseTracks(entity['trackList']).map(
      (track) => PlaylistTrack.fromSpotify(track, null),
    );
    final savedMatches = <String, PlaylistTrack>{};
    for (final saved in existingMatches?.call(id) ?? const <PlaylistTrack>[]) {
      if (saved.spotify != null &&
          !saved.isUnmatchedSpotify &&
          (saved.spotifyMatchIsManual || saved.source == source)) {
        savedMatches[saved.identityKey] = saved;
      }
    }
    SpotifyMatchIssues? matchIssues;
    final results = await rematchUnmatched(
      [
        for (final track in originals)
          savedMatches[track.identityKey]?.mergePreferLocal(track) ?? track,
      ],
      source: source,
      onProgress: onProgress,
      cancelled: cancelled,
      onIssues: (issues) => matchIssues = issues,
    );
    final art = entity['coverArt'];
    final sources = art is Map ? art['sources'] : null;
    final cover = sources is List && sources.isNotEmpty ? sources.first : null;
    return SpotifyPlaylistPreview(
      id: id,
      name: entity['name'] as String,
      creator: entity['subtitle'] as String?,
      coverUrl: cover is Map ? cover['url'] as String? : null,
      total: total,
      hasMatchingPlatforms: true,
      tracks: results,
      matchIssues: matchIssues,
    );
  }

  Future<List<PlaylistTrack>> rematchUnmatched(
    List<PlaylistTrack> tracks, {
    MusicSource source = MusicSource.wy,
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
    void Function(SpotifyMatchIssues issues)? onIssues,
  }) async {
    final snapshot = List<PlaylistTrack>.unmodifiable(tracks);
    if (cancelled?.call() == true) return snapshot;
    final indices = [
      for (var i = 0; i < snapshot.length; i++)
        if (snapshot[i].isUnmatchedSpotify) i,
    ];
    if (indices.isEmpty) return snapshot;
    final platforms = await enabledPlatforms();
    if (cancelled?.call() == true) return snapshot;
    if (source == MusicSource.all || !platforms.contains(source)) {
      throw StateError('${source.label}未启用或不可用');
    }
    final results = [...snapshot];
    var nextIndex = 0;
    var done = 0;
    var completedSearches = 0;
    var failed = 0;
    var unfinished = 0;
    var rateLimited = false;
    bool canSearch(int index) {
      final track = snapshot[index].spotify!;
      return track.type == 'track' && track.artist.isNotEmpty;
    }

    onProgress?.call(0, indices.length);
    Future<void> matchNext() async {
      while (!rateLimited &&
          nextIndex < indices.length &&
          cancelled?.call() != true) {
        final index = indices[nextIndex++];
        final original = snapshot[index];
        final track = original.spotify!;
        if (canSearch(index)) {
          try {
            final candidates = await search(
              '${track.title} ${track.artist}',
              source,
            );
            if (cancelled?.call() == true) return;
            final initial = _rankMatches(track, candidates, source);
            var match = initial.match;
            // A different query can omit part of an already-known tie.
            if (match == null && !initial.ambiguous) {
              if (rateLimited) {
                unfinished++;
                return;
              }
              final titleResults = await search(track.title, source);
              if (cancelled?.call() == true) return;
              match = _rankMatches(track, titleResults, source).match;
            }
            if (match != null) {
              results[index] = PlaylistTrack.fromSpotify(track, match).copyWith(
                localPath: original.localPath,
                playlistEntryKey: original.playlistEntryKey,
              );
            }
            completedSearches++;
          } on Exception catch (error) {
            if (cancelled?.call() == true) return;
            failed++;
            final httpStatus = switch (error) {
              WySearchException() => error.httpStatus,
              DioException() => error.response?.statusCode,
              _ => null,
            };
            final responseCode = error is WySearchException
                ? error.responseCode
                : null;
            if (httpStatus == 429 || responseCode == 405 || responseCode == 429) {
              rateLimited = true;
            }
            unawaited(
              AppLogger.write(
                'spotify-import',
                '${source.code} search failed (${error.runtimeType})'
                '${httpStatus == null ? '' : ' http=$httpStatus'}'
                '${responseCode == null ? '' : ' code=$responseCode'}',
              ),
            );
            continue;
          }
        }
        if (cancelled?.call() == true) return;
        onProgress?.call(++done, indices.length);
      }
    }

    await Future.wait(List.generate(3, (_) => matchNext()));
    if (cancelled?.call() == true) return snapshot;
    if (failed > 0) {
      if (completedSearches == 0) {
        throw StateError(
          rateLimited
              ? '${source.label}搜索请求过于频繁，请稍后重试'
              : '${source.label}搜索失败，请重试',
        );
      }
      unfinished += indices.skip(nextIndex).where(canSearch).length;
      onIssues?.call(
        SpotifyMatchIssues(
          failed: failed,
          unfinished: unfinished,
          rateLimited: rateLimited,
        ),
      );
    }
    return List.unmodifiable(results);
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

int? _exactDurationMs(MusicInfo music) {
  final value = music.meta.raw['durationMs'];
  return value is int && value > 0 ? value : null;
}

int? _durationMs(MusicInfo music) {
  final exact = _exactDurationMs(music);
  if (exact != null) return exact;
  final parts = music.interval?.split(':').map(int.tryParse).toList();
  if (parts == null ||
      parts.length < 2 ||
      parts.length > 3 ||
      parts.any((part) => part == null || part < 0) ||
      parts.skip(1).any((part) => part! >= 60)) {
    return null;
  }
  final ms = parts.fold<int>(0, (n, part) => n * 60 + part!) * 1000;
  return ms > 0 ? ms : null;
}

bool? _knownExplicit(MusicInfo music) {
  final value = music.meta.raw['isExplicit'] ?? music.raw['isExplicit'];
  return value is bool ? value : null;
}

final _recordingQualifier = RegExp(
  r'\([^()]*\)|\[[^\[\]]*\]|（[^（）]*）|【[^【】]*】|(?:\s+[-–—]\s+|:\s+).+$',
);
final _liveLocation = RegExp(
  r'\blive\s+(?:at|in|from)\b',
  caseSensitive: false,
);
final _liveAlbumLabel = RegExp(
  r'(?:^|\s)(?!to\b)\S+\s+live$|现场\s*演唱会|演唱会\s*现场',
  caseSensitive: false,
);
final _recordingTagsByName = {
  for (final tag in [
    r'\blive\b|现场', r'\bremix\b|混音', r'\bclean\b',
    r'\binstrumental\b|伴奏', r'\bkaraoke\b', r'\bcover\b|翻唱',
    r'\bsped[ -]?up\b|\bspeed[ -]?up\b|加速',
    r'\bslowed\b|慢速|降速', r'\bacoustic\b', r'\bremaster(?:ed)?\b',
  ])
    tag: (
      qualifier: RegExp(tag, caseSensitive: false),
      label: RegExp(
        '^(?:$tag)\$|(?:$tag)'
        r'(?:\s+(?:versions?|editions?|recordings?|albums?|mixes?|\d{4})\b|版|录音|专辑)',
        caseSensitive: false,
      ),
    ),
};

String _recordingTags(String title, [String album = '']) {
  final albumName = album.trim();
  final names = [title.trim(), albumName];
  final qualifiers = [
    for (final name in names)
      for (final match in _recordingQualifier.allMatches(name)) match[0]!,
    if (names.any(_liveLocation.hasMatch) || _liveAlbumLabel.hasMatch(albumName))
      'live',
  ].join(' ');
  return [
    for (final tag in _recordingTagsByName.entries)
      if (tag.value.qualifier.hasMatch(qualifiers) ||
          names.any(tag.value.label.hasMatch))
        tag.key,
  ].join('|');
}

bool _sameRelease(MusicInfo a, MusicInfo b) {
  final duration = _exactDurationMs(a);
  // Second-only legacy data is not proof that different IDs are duplicates.
  return duration != null && duration == _exactDurationMs(b) &&
      _normalize(a.name) == _normalize(b.name) &&
      _artists(a.singer) == _artists(b.singer) &&
      _normalize(a.albumName).isNotEmpty &&
      _normalize(a.albumName) == _normalize(b.albumName) &&
      _recordingTags(a.name, a.albumName) ==
          _recordingTags(b.name, b.albumName) &&
      _knownExplicit(a) == _knownExplicit(b);
}

({MusicInfo? match, bool ambiguous}) _rankMatches(
  SpotifyTrackMetadata track,
  List<MusicInfo> candidates,
  MusicSource source,
) {
  final title = _normalize(track.title);
  final artist = _normalize(track.artist);
  if (title.isEmpty || artist.isEmpty) return (match: null, ambiguous: false);
  final artists = _artists(track.artist);
  final recordingTags = _recordingTags(track.title);
  final best = <MusicInfo>[];
  int? smallestDifference;
  for (final candidate in candidates) {
    if (candidate.source != source ||
        candidate.id.trim().isEmpty ||
        _normalize(candidate.name) != title ||
        _recordingTags(candidate.name, candidate.albumName) != recordingTags ||
        (track.explicit != null &&
            _knownExplicit(candidate) != null &&
            track.explicit != _knownExplicit(candidate)) ||
        (_normalize(candidate.singer) != artist &&
            _artists(candidate.singer) != artists)) {
      continue;
    }
    final ms = _durationMs(candidate);
    final int difference;
    if (track.durationMs != null && track.durationMs! > 0) {
      if (ms == null) continue;
      difference = (ms - track.durationMs!).abs();
      if (difference > 4000) continue;
    } else {
      difference = 0;
    }
    if (smallestDifference == null || difference < smallestDifference) {
      best
        ..clear()
        ..add(candidate);
      smallestDifference = difference;
    } else if (difference == smallestDifference) {
      best.add(candidate);
    }
  }
  if (best.isEmpty) return (match: null, ambiguous: false);
  final first = best.first;
  for (final candidate in best.skip(1)) {
    if (candidate.id != first.id && !_sameRelease(first, candidate)) {
      return (match: null, ambiguous: true);
    }
  }
  // ID orders equivalent entries only; it says nothing about audio quality.
  best.sort((a, b) => a.id.compareTo(b.id));
  return (match: best.first, ambiguous: false);
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
