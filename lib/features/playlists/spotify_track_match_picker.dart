import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/enums.dart';
import '../../core/models/music_info.dart';
import '../search/search_controller.dart';
import '../search/search_page.dart';
import 'playlist_models.dart';

Future<MusicInfo?> pickSpotifyTrackMatch(
  BuildContext context,
  PlaylistTrack track, {
  MusicSource? initialSource,
}) async {
  final original = track.spotify;
  if (original == null) return null;
  Widget buildPage(BuildContext context) => ProviderScope(
    overrides: [searchControllerProvider.overrideWith(SearchController.new)],
    child: SearchPage.songPicker(
      initialKeyword: '${original.title} ${original.artist}'.trim(),
      initialSource:
          initialSource ?? track.musicInfo?.source ?? MusicSource.all,
      onSongSelected: (music) => Navigator.of(context).pop(music),
    ),
  );

  return Navigator.of(context, rootNavigator: true).push(
    Theme.of(context).platform == TargetPlatform.iOS
        ? CupertinoPageRoute<MusicInfo>(builder: buildPage)
        : MaterialPageRoute<MusicInfo>(builder: buildPage),
  );
}
