import 'package:shared_preferences/shared_preferences.dart';

/// Simple on-disk cache for raw HTML pages fetched through the (expensive,
/// WebView-based) [PgupsHttpClient].
///
/// Every page is cached under its own URL, so the app can render instantly
/// from disk on every normal open — without spending a single WebView
/// request — and only hits the network when the user explicitly asks for
/// it (pull-to-refresh). This is what makes the app usable offline: the
/// last successfully loaded groups list / schedule is always available,
/// even with no internet connection at all.
class PgupsCacheService {
  PgupsCacheService._();
  static final PgupsCacheService instance = PgupsCacheService._();

  static const _prefix = 'pgups_page_cache_v1_';
  static const _timePrefix = 'pgups_page_cache_time_v1_';

  /// Returns the cached HTML for [key] (usually the page URL), or null if
  /// nothing has been cached for it yet.
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$key');
  }

  /// Timestamp of the last successful [write] for [key], if any.
  Future<DateTime?> readSavedAt(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt('$_timePrefix$key');
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> write(String key, String html) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$key', html);
    await prefs.setInt('$_timePrefix$key', DateTime.now().millisecondsSinceEpoch);
  }
}
