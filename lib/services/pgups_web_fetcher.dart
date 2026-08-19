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
    // Only meaningful for the top-level document; subresource errors (a
    // missing image/font/blocked analytics or ad script, etc.) are
    // extremely common on a perfectly normal page load and must NOT fail
    // the whole fetch.
    //
    // Trust `isForMainFrame` when the platform actually reports it (either
    // true or false). Only fall back to URL-matching when that flag is
    // unavailable — and even then, if we can't determine a URL either,
    // treat it as a subresource rather than guessing "main frame": a
    // wrong "true" guess here breaks every normal load that happens to
    // have one blocked tracker, whereas a wrong "false" guess just means
    // we fall through to _extractHtml(), which is exactly the safe,
    // pre-existing fallback behavior for an unclassifiable error anyway.
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

  /// Loads [url] in the shared WebView, waits for the page (and any
  /// JS-driven anti-bot reload) to settle, then returns the resulting HTML.
  Future<PgupsResponse> get(String url) async {
    final controller = _controller;
    if (controller == null) {
      throw StateError(
          'WebView ещё не готов — попробуйте ещё раз через мгновение.');
    }

    _lastMainFrameStatus = null;
    _lastMainFrameError = null;
    _targetUri = Uri.parse(url);

    await controller.loadRequest(_targetUri!);
    await _waitForSettledLoad();

    // If the WebView itself failed to reach the page, Chromium still
    // finishes "loading" — it just loads its own native error page
    // ("Webpage not available") and fires onPageFinished as normal. Left
    // unchecked, that error page's HTML gets scraped and handed to
    // GroupsService/ScheduleService as if it were real site content
    // (this is exactly what produced the garbled "Не удалось загрузить
    // список групп... <html><head>..." error users would otherwise see).
    // Catch that here and fail loudly with a real network error instead.
    final resourceError = _lastMainFrameError;
    if (resourceError != null) {
      throw PgupsNetworkException(
        url,
        resourceError.description,
        resourceError.errorCode,
      );
    }

    final html = await _extractHtml(controller);

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
  