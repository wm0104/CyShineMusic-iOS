import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/artist_info.dart';
import '../../../core/models/online_collection_kind.dart';
import '../../../core/models/playlist_summary.dart';
import '../../../core/ui/container_transform.dart';
import '../../discovery/discovery_controller.dart';
import '../../discovery/widgets/discovery_playlist_cover.dart';

/// The same artist row is used by search and the current-track artist list.
class ArtistResultTile extends StatelessWidget {
  const ArtistResultTile({super.key, required this.artist, this.from});
  final ArtistInfo artist;
  final String? from;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('artist-${artist.source.code}-${artist.id}'),
      minTileHeight: 62,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      horizontalTitleGap: 8,
      leading: Hero(
        tag: onlinePlaylistArtworkHeroTag(artist.source, artist.id,
          kind: OnlineCollectionKind.artist),
        createRectTween: containerTransformHeroRectTween,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(dimension: 44,
            child: DiscoveryPlaylistCover(url: artist.coverUrl, size: 44)),
        ),
      ),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.onSurface)),
      subtitle: Text(artist.source.label,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.push(
        '/discover/artists/${artist.source.code}/${Uri.encodeComponent(artist.id)}'
        '${from == null ? '' : '?from=${Uri.encodeQueryComponent(from!)}'}',
        extra: ContainerTransformExtra(
          PlaylistSummary(id: artist.id, name: artist.name, source: artist.source,
            coverUrl: artist.coverUrl),
          origin: ContainerTransformOrigin.capture(context, color: scheme.surface),
        ),
      ),
    );
  }
}
