import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'vector_signal.dart';

/// What a tap landed on, sent as the `target` property of `$tap`.
/// Only [button] taps can become "dead taps" on the server: blank space,
/// switches/tabs and text fields can work without a screen change or API call.
enum TapTarget {
  /// Something with a tap action: buttons, list tiles, InkWell, GestureDetector(onTap).
  button,

  /// A control that changes in place: switch, checkbox, radio, tab, expandable tile.
  toggle,

  /// A text field (the tap opens the keyboard).
  text,

  /// Nothing tappable under the finger.
  none,
}

/// Finds what is under a tap using Flutter's own hit test and the semantics
/// that buttons and controls already declare for accessibility.
/// It never reads any text.
class TapTargetClassifier {
  TapTargetClassifier._();

  /// How far above the tap action to look for a toggle/selected state. Material
  /// controls put the state a few render objects above their InkWell.
  static const int _stateSearchDepth = 8;

  static TapTarget classify(Offset position, int viewId) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, position, viewId);
      return classifyPath(result.path.map((e) => e.target));
    } catch (_) {
      return TapTarget.none;
    }
  }

  /// [targets] innermost first, as in [HitTestResult.path]. Visible for tests.
  static TapTarget classifyPath(Iterable<HitTestTarget> targets) {
    final path = targets.toList();
    int? actionAt;
    for (var i = 0; i < path.length; i++) {
      final target = path[i];
      if (target is RenderEditable) return TapTarget.text;
      if (_hasTapAction(target)) {
        actionAt = i;
        break;
      }
    }
    if (actionAt == null) return TapTarget.none;

    final end = (actionAt + _stateSearchDepth).clamp(0, path.length - 1);
    for (var i = 0; i <= end; i++) {
      final target = path[i];
      if (target is RenderSemanticsAnnotations &&
          _isStateful(target.properties)) {
        return TapTarget.toggle;
      }
    }
    return TapTarget.button;
  }

  static bool _hasTapAction(HitTestTarget target) =>
      (target is RenderSemanticsGestureHandler && target.onTap != null) ||
      (target is RenderSemanticsAnnotations && target.properties.onTap != null);

  static bool _isStateful(SemanticsProperties p) =>
      p.toggled != null ||
      p.checked != null ||
      p.selected != null ||
      p.expanded != null ||
      p.textField == true;
}

/// Decides whether a pointer down/up pair was a tap (not a drag or long press).
class TapClassifier {
  TapClassifier._();

  static const Duration maxDuration = Duration(milliseconds: 300);
  static const double maxMovement = 18;

  static bool isTap(Offset down, Offset up, Duration held) =>
      held <= maxDuration && (up - down).distance <= maxMovement;
}

/// Wrap your app (e.g. in `MaterialApp.builder`) to record `$tap` events:
/// position, current screen and the [VSLabel] under the finger, if any.
/// It never reads any text from widgets.
class VectorSignalTapCapture extends StatefulWidget {
  final Widget child;

  const VectorSignalTapCapture({super.key, required this.child});

  @override
  State<VectorSignalTapCapture> createState() => _VectorSignalTapCaptureState();
}

class _VectorSignalTapCaptureState extends State<VectorSignalTapCapture> {
  final Map<int, ({Offset position, DateTime time})> _downs = {};

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _downs[e.pointer] = (position: e.position, time: DateTime.now());
        VectorSignal.replay?.notifyInteraction();
      },
      // Scrolling and dragging: keep replay frames coming while the finger moves.
      onPointerMove: (_) => VectorSignal.replay?.notifyInteraction(),
      onPointerCancel: (e) => _downs.remove(e.pointer),
      onPointerUp: (e) {
        final down = _downs.remove(e.pointer);
        if (down == null) return;
        if (TapClassifier.isTap(
            down.position, e.position, DateTime.now().difference(down.time))) {
          VectorSignal.recordTap(e.position,
              label: VSLabel.labelAt(e.position),
              target:
                  TapTargetClassifier.classify(down.position, e.viewId).name);
        }
      },
      // Session replay captures this area (only when replay is enabled).
      child: RepaintBoundary(
        key: VectorSignal.replayBoundaryKey,
        child: widget.child,
      ),
    );
  }
}

/// Gives a widget a stable name in tap events, e.g.
/// `VSLabel(name: 'create_session', child: FilledButton(...))`.
/// Use short ids, never user data.
class VSLabel extends StatefulWidget {
  final String name;
  final Widget child;

  const VSLabel({super.key, required this.name, required this.child});

  static final Set<_VSLabelState> _mounted = {};

  /// The label whose area contains [globalPosition]; the smallest wins when nested.
  static String? labelAt(Offset globalPosition) {
    String? best;
    double? bestArea;
    for (final state in _mounted) {
      final rect = state.globalRect();
      if (rect == null || !rect.contains(globalPosition)) continue;
      final area = rect.width * rect.height;
      if (bestArea == null || area < bestArea) {
        best = state.widget.name;
        bestArea = area;
      }
    }
    return best;
  }

  @override
  State<VSLabel> createState() => _VSLabelState();
}

class _VSLabelState extends State<VSLabel> {
  @override
  void initState() {
    super.initState();
    VSLabel._mounted.add(this);
  }

  @override
  void dispose() {
    VSLabel._mounted.remove(this);
    super.dispose();
  }

  Rect? globalRect() {
    if (!mounted) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
