import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import 'pgups_response.dart';

/// Thrown when the WebView itself failed to reach [url] (offline, DNS
/// failure, timeout, TLS error, ...) — i.e. Chromium's own native error
/// page ("Webpage not available" / net::ERR_...) loaded instead of the
/// real site. This is deliberately a *different* exception from
/// [GroupsFetchException]-style "page loaded but had no groups on it"
/// failures, so callers (and their error messages) don't confuse "you're
/// offline" with "the site's markup changed".
class PgupsNetworkException implements Exception {
  final String description;
  final int? errorCode;
  final String url;

  PgupsNetworkException(this.url, this.description, [this.errorCode]);

  @override
  String toString() =>
      'Не удалось загрузить страницу — проверьте подключение к интернету '
      '($description${errorCode != null ? ', код $errorCode' : ''})';
}

/// Fetches pages from rasp.pgups.ru through a real [WebViewController]
/// instead of a plain HTTP client.
///
/// The site started rejecting plain requests with:
///   x-humantoken: invalid_or_not_accepted
/// which is a token computed by JavaScript running on the page (a browser
/// anti-bot check) — something a `package:http` request can never produce,
/// no matter which headers/cookies it replays. A WebView runs the site's
/// real JS and real cookie jar, so from the server's point of view it's a
/// normal browser visit.
///
/// A single [WebViewController] is reused for the app's lifetime (attached
/// once by [PgupsWebViewHost]) so its cookie jar persists across requests,
/// exactly like a browser tab staying open.
class PgupsWebFetcher {
  PgupsWebFetcher._();
  static final PgupsWebFetcher instance = PgupsWebFetcher._();

  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125 Mobile Safari/537.36';

  WebViewController? _controller;
  final _pageFinished = StreamController<String>.broadcast();
  int? _lastMainFrameStatus;
  WebResourceError? _lastMainFrameError;
  Uri? _targetUri;

  bool get isReady => _controller != null;

  /// Called once by [PgupsWebViewHost] when its controller is created.
  void attach(WebViewController controller) {
    _controller = controller;
  }

  // --- callbacks wired up by PgupsWebViewHost's NavigationDelegate --------

  void onPageFinished(String url) {
    _pageFinished.add(url);
  }

  void onHttpError(HttpResponseError error) {
    // Only meaningful for the top-level document; subresource errors
    // (a missing image/font, etc.) shouldn't fail the whole fetch.
    //
    // `WebResourceResponse` (unlike `WebResourceError`) has no
    // `isForMainFrame` field in this version of
    // webview_flutter_platform_interface, so we approximate "is this the
    // top-level document" by checking whether the response's URI matches
    // the URL we asked the WebView to load.
    final responseUri = error.response?.uri ?? error.request?.uri;
    final isMainFrame = _targetUri == null || responseUri == null
        ? true
        : responseUri == _targetUri;
    if (isMainFrame) {
      _lastMainFrameStatus = error.response?.statusCode;
    }
  }

  void onWebResourceError(WebResourceError error) {
    // Best-effort diagnostic info only (used for the exception's message
    // if we do end up throwing one, based on the content check in get()
    // below) — not itself the trigger for treating the fetch as failed.
    // See the comment in get() for why: `isForMainFrame` isn't reliably
    // meaningful for every kind of request across WebView versions.
    final isForMainFrame = error.isForMainFrame;
    final bool isMainFrame;
    if (isForMainFrame != null) {
      isMainFrame = isForMainFrame;
    } else {
      final errorUri = error.url != null ? Uri.tryParse(error.url!) : null;
      isMainFrame = errorUri != null && errorUri == _targetUri;
    }
    if (isMainFrame) {
      _lastMainFrameError = error;
    }
  }

  /// Detects a browser-generated "the page didn't load" interstitial,
  /// as opposed to real site content. Two different templates have shown
  /// up in the wild, depending on the WebView engine/version:
  ///  - Chrome's own neterror interstitial, which always contains a
  ///    container with this id, regardless of the specific net::ERR_*
  ///    reason or the device's locale.
  ///  - Android System WebView's older, separate built-in error page,
  ///    which instead uses a fixed, English, locale-independent
  ///    "Webpage not available" title (seen directly in the wild on a
  ///    real device — the screenshot that prompted this check). A page
  ///    titled exactly that is not something the real site would ever
  ///    render, so matching the title is safe.
  bool _looksLikeNetworkErrorPage(String html) {
    if (html.contains('id="main-frame-error"') ||
        html.contains("id='main-frame-error'")) {
      return true;
    }
    final titleMatch =
        RegExp(r'<title>\s*([^<]*)\s*</title>', caseSensitive: false)
            .firstMatch(html);
    final title = titleMatch?.group(1)?.trim().toLowerCase();
    return title == 'webpage not available';
  }

  /// Loads [url] in the shared WebView, waits for the page (and any
  /// JS-driven anti-bot reload) to settle, then returns the resulting HTML.
  Future<PgupsResponse> get(String url) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError(
          'WebView ещё не готов — попробуйте ещё раз через мгновение.');
    }

    _targetUri = Uri.parse(url);

    _lastMainFrameStatus = null;
    _lastMainFrameError = null;

    await controller.loadRequest(_targetUri!);
    await _waitForSettledLoad();

    // If the WebView itself failed to reach the page, Chromium still
    // finishes "loading" — it just loads its own native error page
    // ("Webpage not available") and fires onPageFinished as normal. Left
    // unchecked, that error page's HTML gets scraped and handed to
    // GroupsService/ScheduleService as if it were real site content
    // (this is exactly what produced the garbled "Не удалось загрузить
    // список групп... <html><head>..." error users would otherwise see).
    //
    // We deliberately do NOT decide this from onWebResourceError firing:
    // that callback also fires for things that never affect the real page
    // — a blocked tracker, a missing favicon, or (as seen in the wild,
    // release-build-only) the site's own JS doing a cache-probe fetch()
    // to the exact same URL that intentionally raises net::ERR_CACHE_MISS
    // and handles it itself. Whether isForMainFrame is trustworthy for
    // that kind of request varies by WebView engine version/device, so
    // gating on it caused false positives even after real page loads.
    // Instead we check what actually got rendered: a browser-generated
    // "page didn't load" interstitial, detected via
    // _looksLikeNetworkErrorPage (see its doc comment for the two
    // templates this covers).
    //
    // NOTE: this method deliberately does NOT retry internally. A single
    // bad round trip (false-positive race, transient net::ERR_TIMED_OUT,
    // ...) is instead absorbed by the retry loop that already lives one
    // layer up, in GroupsService/ScheduleService's `_fetchFromNetwork`
    // (3 attempts with backoff, falling back to cache on final failure).
    // Retrying at both layers previously multiplied into up to 3×3 = 9
    // full WebView loads (each with its own ~20s timeout) before ever
    // reaching the cache fallback — which looked like the app hanging /
    // "everything breaking" rather than the intended fast cache-first,
    // network-in-background behavior.
    final html = await _extractHtml(controller);
    if (_looksLikeNetworkErrorPage(html)) {
      final err = _lastMainFrameError;
      throw PgupsNetworkException(
        url,
        err?.description ?? 'страница не открылась',
        err?.errorCode,
      );
    }

    return PgupsResponse(
      statusCode: _lastMainFrameStatus ?? 200,
      body: html,
      headers: const {},
    );
  }

  /// Waits for the first `onPageFinished`, then keeps waiting through a
  /// short quiet window: some anti-bot scripts set their cookie/token and
  /// then reload or client-side-redirect the page once, which fires a
  /// second `onPageFinished`. We only consider the load "settled" once
  /// nothing new has finished for [_quietWindow].
  static const _quietWindow = Duration(milliseconds: 800);
  static const _firstLoadTimeout = Duration(seconds: 20);
  static const _maxSettleRounds = 4;

  Future<void> _waitForSettledLoad() async {
    await _pageFinished.stream.first.timeout(_firstLoadTimeout);

    for (var round = 0; round < _maxSettleRounds; round++) {
      var firedAgain = false;
      try {
        await _pageFinished.stream.first.timeout(_quietWindow);
        firedAgain = true;
      } on TimeoutException {
        firedAgain = false;
      }
      if (!firedAgain) return; // quiet for a full window: settled
    }
    // Gave the challenge script every reasonable chance to finish
    // reloading; proceed with whatever's currently loaded.
  }

  Future<String> _extractHtml(WebViewController controller) async {
    final raw = await controller
        .runJavaScriptReturningResult('document.documentElement.outerHTML');
    return _decodeJsResult(raw);
  }

  /// `runJavaScriptReturningResult` returns a JSON-encoded string on
  /// Android (wrapped in `"..."` with escapes) and a plain Dart string on
  /// iOS — normalize both to a plain string.
  String _decodeJsResult(Object raw) {
    final s = raw.toString();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        return jsonDecode(s) as String;
      } catch (_) {
        // fall through and use the raw string as-is
      }
    }
    return s;
  }
}
