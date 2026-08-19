import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/pgups_web_fetcher.dart';

/// Mounts one persistent, invisible-to-the-user [WebView] that
/// [PgupsWebFetcher] drives to load rasp.pgups.ru pages (so the site's JS
/// anti-bot check runs and its cookies are kept, like a real browser tab).
///
/// Wrap the whole app with this once (see `main.dart`'s `MaterialApp.builder`)
/// so the same [WebViewController] — and its cookie jar — survives
/// navigation between screens instead of being recreated per request.
///
/// The WebView is kept at full, on-screen size rather than moved off-canvas
/// or given a degenerate size: the site's anti-bot JS challenge behaves
/// unreliably at anything other than a normal, full browser-window
/// viewport (confirmed by testing — both a 1x1 WebView and one positioned
/// off-screen reliably failed the challenge, even though the site itself
/// was up). So it sits *underneath* the real app UI in a [Stack], fully on
/// screen, just never visible because the app's own UI fully covers it.
class PgupsWebViewHost extends StatefulWidget {
  final Widget child;
  const PgupsWebViewHost({super.key, required this.child});

  @override
  State<PgupsWebViewHost> createState() => _PgupsWebViewHostState();
}

class _PgupsWebViewHostState extends State<PgupsWebViewHost> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(PgupsWebFetcher.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: PgupsWebFetcher.instance.onPageFinished,
          onHttpError: PgupsWebFetcher.instance.onHttpError,
          onWebResourceError: PgupsWebFetcher.instance.onWebResourceError,
        ),
      );
    PgupsWebFetcher.instance.attach(_controller);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: WebViewWidget(controller: _controller),
          ),
        ),
        widget.child,
      ],
    );
  }
}
