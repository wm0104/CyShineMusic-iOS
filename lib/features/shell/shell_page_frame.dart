import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/storage/settings_store.dart';
import 'shell_bottom_area.dart';
import 'shell_edge_back.dart';
import 'shell_route_utils.dart';
import 'widgets/shell_header.dart';

/// Each retained route owns its header, so changing tabs cannot resize another
/// tab's scroll viewport and clamp its saved position.
class ShellPageFrame extends StatelessWidget {
  const ShellPageFrame({
    super.key,
    required this.location,
    required this.playlistBackLocation,
    required this.child,
  });

  final String location;
  final String playlistBackLocation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final area = ShellBottomArea.maybeOf(context);
    // On iOS the capsule has its own SafeArea. Let the list paint under
    // the home indicator; its trailing padding keeps the last row tappable.
    final capsulePadding = Theme.of(context).platform == TargetPlatform.iOS
        ? 0.0
        : math.max(MediaQuery.viewPaddingOf(context).bottom, 12.0);
    final bottomPadding = area?.navigationMode == AppNavigationMode.native
        ? area!.extent > 0
              ? area.extent - area.floatingExtent
              : MediaQuery.paddingOf(context).bottom
        : capsulePadding;
    final hidesHeader =
        isDiscoveryLocation(location) ||
        isPlaybackArtistLocation(location) ||
        isImmersivePlaylistDetailLocation(location);
    final content = Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Column(
        children: [
          if (!hidesHeader)
            ShellHeader(
              location: location,
              playlistBackLocation: playlistBackLocation,
            ),
          Expanded(child: child),
        ],
      ),
    );
    final back = ShellEdgeBackScope.maybeOf(context);
    final route = ModalRoute.of(context);
    if (back == null || route == null || isTopLevelShellLocation(location)) {
      return content;
    }
    return ShellEdgeBack(
      canStart: () =>
          back.location == location &&
          route.isCurrent &&
          route.animation?.isCompleted != false &&
          route.secondaryAnimation?.isDismissed != false &&
          !route.willHandlePopInternally &&
          !Navigator.of(context, rootNavigator: true).canPop(),
      onBack: () => back.onBack(context),
      child: content,
    );
  }
}
