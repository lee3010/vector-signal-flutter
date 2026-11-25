/// Turns a request into a stable, privacy-safe name such as `GET /api/Agent/{id}`.
///
/// Only the method and the path are used: never the query string, headers or
/// body. Path segments that look like ids or personal values (anything with a
/// digit or `@`, or very long) become `{id}`, so `/api/Agent/AGA003` and
/// `/api/Agent/AGA004` are one API in the dashboard. Version segments like
/// `v1` are kept.
///
/// Keep in sync with `ApiCallNames.kt` in the Android part of this SDK.
class ApiCallNames {
  ApiCallNames._();

  static const int _maxLength = 200;
  static const int _maxSegmentLength = 40;
  static final RegExp _version = RegExp(r'^v\d+$', caseSensitive: false);
  static final RegExp _digit = RegExp(r'\d');

  static String name(String method, Iterable<String> pathSegments) {
    final value = '${method.toUpperCase()} ${normalizePath(pathSegments)}';
    return value.length <= _maxLength ? value : value.substring(0, _maxLength);
  }

  static String fromUri(String method, Uri uri) =>
      name(method, uri.pathSegments);

  static String normalizePath(Iterable<String> pathSegments) =>
      '/${pathSegments.where((s) => s.isNotEmpty).map((s) => _isIdLike(s) ? '{id}' : s).join('/')}';

  static bool _isIdLike(String segment) =>
      !_version.hasMatch(segment) &&
      (_digit.hasMatch(segment) ||
          segment.contains('@') ||
          segment.length > _maxSegmentLength);
}
