/// Utility for signaling cancellation across the agent loop and providers.
library;

import 'dart:async';

class CancellationToken {
  final List<void Function()> _listeners = [];
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  /// Signals that the operation should be cancelled.
  /// Any registered listeners will be invoked immediately.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in _listeners) {
      try {
        listener();
      } catch (_) {
        // Ignore listener errors during cancellation
      }
    }
    _listeners.clear();
  }

  /// Registers a callback to be invoked when [cancel] is called.
  /// If the token is already cancelled, the listener is invoked immediately.
  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  /// Removes a previously registered listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Throws a [CanceledException] if the token has been cancelled.
  void throwIfCancelled() {
    if (_isCancelled) throw const CanceledException();
  }
}

class CanceledException implements Exception {
  const CanceledException();
  @override
  String toString() => 'Operation was cancelled';
}
