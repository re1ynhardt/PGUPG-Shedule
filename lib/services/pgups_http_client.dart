import 'pgups_response.dart';
import 'pgups_web_fetcher.dart';

/// Same call shape as before (`PgupsHttpClient.instance.get(url)` ->
/// status/body/headers), so `groups_service.dart` and `schedule_service.dart`
/// don't need to change at all. Internally this now goes through a real
/// [WebView] (see [PgupsWebFetcher]) instead of a plain HTTP request,
/// because rasp.pgups.ru added a JS-computed anti-bot token
/// (`x-humantoken`) that no plain HTTP client can produce.
class PgupsHttpClient {
  PgupsHttpClient._();
  static final PgupsHttpClient instance = PgupsHttpClient._();

  static const String origin = 'https://rasp.pgups.ru';

  Future<PgupsResponse> get(String url) => PgupsWebFetcher.instance.get(url);
}
