/// Minimal stand-in for [http.Response] (status/body/headers only — that's
/// all `groups_service.dart` / `schedule_service.dart` ever read), so the
/// rest of the app doesn't need to know whether a page was fetched with the
/// `http` package or rendered in a [WebView].
class PgupsResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  const PgupsResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });
}
