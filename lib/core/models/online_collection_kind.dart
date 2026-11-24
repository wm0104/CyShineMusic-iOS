enum OnlineCollectionKind {
  playlist('歌单', 'playlists'),
  leaderboard('榜单', 'leaderboards'),
  artist('歌手', 'artists');

  const OnlineCollectionKind(this.label, this.path);
  final String label;
  final String path;
}
