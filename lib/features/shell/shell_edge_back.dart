import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ShellEdgeBackScope extends InheritedWidget {
  const ShellEdgeBackScope({
    super.key,
    required this.location,
    required this.onBack,
    required super.child,
  });

  final String location;
  final ValueChanged<BuildContext> onBack;

  static ShellEdgeBackScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellEdgeBackScope>();

  @override
  bool updateShouldNotify(ShellEdgeBackScope oldWidget) =>
      location != oldWidget.location || onBack != oldWidget.onBack;
}

/// Adds iOS left-edge back to a page with an existing back action.
class ShellEdgeBack extends StatefulWidget {
  const ShellEdgeBack({
    super.key,
    required this.canStart,
    required this.onBack,
    required this.child,
  });

  final bool Function() canStart;
  final VoidCallback onBack;
  final Widget child;

  @override
  State<ShellEdgeBack> createState() => _ShellEdgeBackState();
}

class _ShellEdgeBackState extends State<ShellEdgeBack> {
  static const _edgeWidth = 20.0;
  static const _minDistance = 64.0;
  Offset? _origin;
  late final _drag =
      HorizontalDragGestureRecognizer(
          debugOwner: this,
          supportedDevices: const {PointerDeviceKind.touch},
        )
        ..onDown = (details) {
          _origin = details.globalPosition;
        }
        ..onCancel = () {
          _origin = null;
        }
        ..onEnd = _finish;

  void _finish(DragEndDetails details) {
    final origin = _origin;
    _origin = null;
    if (origin == null) return;
    final travel = details.globalPosition - origin;
    if (travel.dx >= _minDistance &&
        travel.dx > travel.dy.abs() &&
        widget.canStart()) {
      widget.onBack();
    }
  }

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return widget.child;

    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned(
          top: 0,
          bottom: 0,
          left: 0,
          width: math.max(_edgeWidth, MediaQuery.viewPaddingOf(context).left),
          // Like Cupertino's edge detector, enter the gesture arena ahead of
          // the page while allowing its taps and vertical drags to compete.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              if (_origin == null && widget.canStart()) _drag.addPointer(event);
            },
            onPointerCancel: (_) => _origin = null,
          ),
        ),
      ],
    );
  }
}
