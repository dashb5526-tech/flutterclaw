import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

final _log = Logger('flutterclaw.overlay');

/// A button option for the interactive message card overlay.
class OverlayButton {
  final String label;
  final String value;
  const OverlayButton({required this.label, required this.value});
}

/// Dart bridge to the Android floating overlay.
/// No-op on iOS.
class OverlayService {
  static const _channel = MethodChannel('ai.flutterclaw/overlay');

  /// Pending message completers keyed by requestId.
  final Map<String, Completer<String>> _pendingRequests = {};
  int _requestCounter = 0;

  OverlayService() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler(_handlePlatformCall);
    }
  }

  /// Handle reverse calls from Android (user tapped a button / submitted text).
  Future<dynamic> _handlePlatformCall(MethodCall call) async {
    if (call.method == 'overlay_user_response') {
      final args = call.arguments as Map?;
      final requestId = args?['requestId'] as String?;
      final value = args?['value'] as String? ?? 'dismissed';
      _log.info('overlay_user_response: requestId=$requestId value=$value');
      if (requestId != null) {
        final completer = _pendingRequests.remove(requestId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(value);
        }
      }
    }
  }

  // ─── Permission ────────────────────────────────────────────────────────────

  Future<bool> checkPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      final result =
          await _channel.invokeMethod<bool>('overlay_check_permission') ??
              false;
      _log.info('checkPermission: $result');
      return result;
    } catch (e) {
      _log.warning('checkPermission error: $e');
      return false;
    }
  }

  Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('overlay_request_permission');
    } catch (e) {
      _log.warning('requestPermission error: $e');
    }
  }

  // ─── Agent identity ────────────────────────────────────────────────────────

  /// Set the agent identity shown on the overlay pill and message card.
  Future<void> setAgent(String name, String emoji) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('overlay_set_agent', {
        'name': name,
        'emoji': emoji,
      });
    } catch (e) {
      _log.warning('setAgent error: $e');
    }
  }

  // ─── Mode A: Status pill ───────────────────────────────────────────────────

  static bool get _isAppInForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> show(String text) async {
    if (!Platform.isAndroid) return;
    if (_isAppInForeground) return;
    try {
      _log.info('show("$text") -> invoking platform channel');
      final result =
          await _channel.invokeMethod<bool>('overlay_show', {'text': text});
      _log.info('show() result: $result');
    } catch (e) {
      _log.warning('show() error: $e');
    }
  }

  Future<void> hide() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('overlay_hide');
    } catch (e) {
      _log.warning('hide() error: $e');
    }
  }

  /// Show a brief "Done" state with a green checkmark, auto-hides after 2s.
  Future<void> showDone() async {
    if (!Platform.isAndroid) return;
    if (_isAppInForeground) return;
    try {
      await _channel
          .invokeMethod<bool>('overlay_show_done', {'text': 'Done'});
    } catch (e) {
      _log.warning('showDone() error: $e');
    }
  }

  // ─── Mode B: Interactive message card ──────────────────────────────────────

  /// Show an interactive message card with buttons or text input.
  ///
  /// Returns the user's response value, or `'timeout'` / `'dismissed'`.
  /// If [textInput] is true, the card shows an EditText + Send button instead
  /// of choice buttons.
  Future<String> showMessage({
    required String text,
    List<OverlayButton>? buttons,
    bool textInput = false,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!Platform.isAndroid) return 'dismissed';
    if (_isAppInForeground) return 'dismissed';

    final requestId = 'msg_${++_requestCounter}';

    // Dismiss any pending message first
    for (final entry in _pendingRequests.entries.toList()) {
      if (!entry.value.isCompleted) {
        entry.value.complete('dismissed');
      }
      _pendingRequests.remove(entry.key);
    }

    final completer = Completer<String>();
    _pendingRequests[requestId] = completer;

    try {
      await _channel.invokeMethod<bool>('overlay_show_message', {
        'text': text,
        'buttons': buttons
            ?.map((b) => {'label': b.label, 'value': b.value})
            .toList(),
        'inputType': textInput ? 'text' : 'buttons',
        'requestId': requestId,
      });
    } catch (e) {
      _log.warning('showMessage error: $e');
      _pendingRequests.remove(requestId);
      return 'dismissed';
    }

    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        _pendingRequests.remove(requestId);
        // Tell Android to dismiss the card
        _channel
            .invokeMethod<bool>('overlay_hide_message')
            .catchError((_) => null);
        return 'timeout';
      });
    } catch (e) {
      _log.warning('showMessage await error: $e');
      _pendingRequests.remove(requestId);
      return 'dismissed';
    }
  }

  /// Dismiss the message card programmatically.
  Future<void> hideMessage() async {
    if (!Platform.isAndroid) return;
    // Resolve any pending completer
    for (final entry in _pendingRequests.entries.toList()) {
      if (!entry.value.isCompleted) {
        entry.value.complete('dismissed');
      }
    }
    _pendingRequests.clear();
    try {
      await _channel.invokeMethod<bool>('overlay_hide_message');
    } catch (e) {
      _log.warning('hideMessage error: $e');
    }
  }

  // ─── Touch feedback (visual indicators for UI automation) ─────────────────

  /// Show a tap ripple at screen coordinates.
  Future<void> showTapFeedback(double x, double y) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod<bool>('overlay_touch_tap', {'x': x, 'y': y});
    } catch (_) {}
  }

  /// Show a swipe trail from (x1,y1) to (x2,y2).
  Future<void> showSwipeFeedback(
      double x1, double y1, double x2, double y2) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('overlay_touch_swipe', {
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
      });
    } catch (_) {}
  }

  /// Show a text-typing bubble.
  Future<void> showTypeFeedback(String text) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel
          .invokeMethod<bool>('overlay_touch_type', {'text': text});
    } catch (_) {}
  }
}
