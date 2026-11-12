import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Smooth mouse-wheel scrolling for one scroll view (installed for every
/// scroll view of the app by its scroll behavior).
///
/// Flutter moves a scroll view by a whole wheel step at once, which looks
/// choppy on desktop. This lets Flutter handle the wheel as usual — so it
/// still decides which view scrolls (inner list, outer page, image zoom…) —
/// then, before the next frame is drawn, puts the view back where it was and
/// animates it to the same place. Several quick wheel steps add up to one
/// glide. Trackpads and touch keep their native behavior.
class SmoothWheelScroll extends StatelessWidget {
  const SmoothWheelScroll({
    required this.controller,
    required this.child,
    super.key,
  });

  final ScrollController? controller;
  final Widget child;

  static const duration = Duration(milliseconds: 220);
  static const curve = Curves.easeOutCubic;

  /// Where each scroll view is gliding to, while it glides.
  static final _targets = Expando<double>();

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.kind != PointerDeviceKind.mouse) {
      return;
    }
    final c = controller;
    if (c == null || c.positions.length != 1) return;
    final position = c.position;
    final from = position.pixels;
    final gliding = _targets[position];
    // Flutter scrolls the view (or not) right after this event; look at
    // the outcome before the frame is drawn.
    scheduleMicrotask(() {
      if (!position.hasPixels || !position.hasContentDimensions) return;
      final step = position.pixels - from;
      if (step == 0) return;
      final target = ((gliding ?? from) + step)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      _targets[position] = target;
      position.jumpTo(from);
      position.animateTo(target, duration: duration, curve: curve).whenComplete(
        () {
          if (_targets[position] == target) _targets[position] = null;
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      Listener(onPointerSignal: _onSignal, child: child);
}
