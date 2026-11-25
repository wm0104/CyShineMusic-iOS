import 'package:flutter/material.dart';

import 'immersive_playlist_chrome.dart';

class PlaylistOrderDragHandle extends StatelessWidget {
  const PlaylistOrderDragHandle({
    super.key,
    required this.index,
    required this.enabled,
  });

  final int index;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ReorderableDragStartListener(
      index: index,
      enabled: enabled,
      child: const SizedBox.square(
        dimension: 44,
        child: Tooltip(
          message: '拖动调整顺序',
          child: Icon(Icons.drag_handle_rounded),
        ),
      ),
    );
  }
}

class PlaylistOrderTopBar extends StatelessWidget {
  const PlaylistOrderTopBar({
    super.key,
    required this.onImage,
    required this.onCancel,
    required this.onComplete,
  });

  final bool onImage;
  final VoidCallback? onCancel;
  final VoidCallback? onComplete;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      foregroundColor: onImage
          ? Colors.white
          : Theme.of(context).colorScheme.onSurface,
    );
    return ImmersivePlaylistTopBar(
      title: '整理顺序',
      onImage: onImage,
      leading: TextButton(
        style: style,
        onPressed: onCancel,
        child: const Text('取消'),
      ),
      actions: [
        TextButton(
          style: style,
          onPressed: onComplete,
          child: const Text('完成'),
        ),
      ],
    );
  }
}
