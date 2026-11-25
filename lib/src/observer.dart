import 'package:flutter/widgets.dart';

import 'vector_signal.dart';

/// Sends a `$screen` event whenever the visible named route changes.
///
/// Works with `MaterialApp(navigatorObservers: [...])` and
/// `GoRouter(observers: [...])`. Routes without a name (most dialogs and
/// bottom sheets) are skipped. Pass [routeName] to name routes yourself.
class VectorSignalObserver extends NavigatorObserver {
  final String? Function(Route<dynamic> route)? routeName;

  VectorSignalObserver({this.routeName});

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _report(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _report(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _report(previousRoute);
  }

  void _report(Route<dynamic> route) {
    final name = nameOf(route);
    if (name == null) return;
    VectorSignal.screen(name);
  }

  /// The name used for [route], or null to skip it.
  String? nameOf(Route<dynamic> route) {
    final custom = routeName?.call(route);
    if (custom != null && custom.isNotEmpty) return custom;
    final name = route.settings.name;
    if (name == null || name.isEmpty) return null;
    return name;
  }
}
