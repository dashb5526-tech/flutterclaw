/// Visible browser overlay for user-assisted actions (CAPTCHA, 2FA, login).
///
/// Shows a full-screen WebView at the current browser URL, sharing the same
/// platform cookie store as the headless browser. The user interacts with the
/// page directly (solving CAPTCHAs, completing 2FA, etc.) then taps Done.
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Full-screen visible browser for user interaction.
///
/// Presented modally over the app. The WebView uses the same platform cookie
/// store as HeadlessBrowserTool — so any session changes (CAPTCHA solved,
/// login completed) are immediately available to the headless browser after
/// the user dismisses this overlay.
class BrowserOverlay extends StatefulWidget {
  final String url;
  final String message;

  const BrowserOverlay({
    super.key,
    required this.url,
    required this.message,
  });

  @override
  State<BrowserOverlay> createState() => _BrowserOverlayState();
}

class _BrowserOverlayState extends State<BrowserOverlay> {
  InAppWebViewController? _controller;
  String _displayUrl = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _displayUrl = widget.url;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            if (_controller != null && await _controller!.canGoBack()) {
              await _controller!.goBack();
            } else {
              if (context.mounted) Navigator.of(context).pop();
            }
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.message,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _displayUrl,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('Done'),
          ),
        ],
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          mediaPlaybackRequiresUserGesture: true,
        ),
        onWebViewCreated: (controller) => _controller = controller,
        onLoadStart: (controller, url) {
          setState(() {
            _loading = true;
            _displayUrl = url?.toString() ?? _displayUrl;
          });
        },
        onLoadStop: (controller, url) {
          setState(() {
            _loading = false;
            _displayUrl = url?.toString() ?? _displayUrl;
          });
        },
        onReceivedError: (controller, request, error) {
          setState(() => _loading = false);
        },
      ),
    );
  }
}
