/// Abstract router for LLM provider selection with failover support.
library;

import 'package:flutterclaw/core/agent/cancel_token.dart';
import 'package:flutterclaw/core/providers/anthropic_provider.dart';
import 'package:flutterclaw/core/providers/bedrock_provider.dart';
import 'package:flutterclaw/core/providers/error_parser.dart';
import 'package:flutterclaw/core/providers/openai_provider.dart';
import 'package:flutterclaw/core/providers/provider_interface.dart';
import 'package:flutterclaw/data/models/config.dart';
import 'package:logging/logging.dart';

final _log = Logger('flutterclaw.provider_router');

abstract class ProviderRouter {
  Future<LlmResponse> chatCompletion(
    LlmRequest request, {
    CancellationToken? cancelToken,
  });
  Stream<LlmStreamEvent> chatCompletionStream(
    LlmRequest request, {
    CancellationToken? cancelToken,
  });
}

class SimpleProviderRouter implements ProviderRouter {
  final LlmProvider provider;

  SimpleProviderRouter(this.provider);

  @override
  Future<LlmResponse> chatCompletion(
    LlmRequest request, {
    CancellationToken? cancelToken,
  }) =>
      provider.chatCompletion(request, cancelToken: cancelToken);

  @override
  Stream<LlmStreamEvent> chatCompletionStream(
    LlmRequest request, {
    CancellationToken? cancelToken,
  }) =>
      provider.chatCompletionStream(request, cancelToken: cancelToken);
}

/// Selects the correct [LlmProvider] implementation based on the request's
/// API base URL. Anthropic uses a different API format from all other
/// OpenAI-compatible providers (different endpoint, auth header, body).
LlmProvider _resolveProvider(LlmRequest request) {
  final base = request.apiBase.toLowerCase();
  if (base.contains('anthropic.com')) {
    return AnthropicProvider();
  }
  if (base.contains('bedrock-runtime')) {
    return BedrockProvider();
  }
  return OpenAiProvider();
}

/// Provider router with automatic retry (exponential backoff) for transient
/// errors and optional fallback to configured secondary models.
///
/// Retry policy (mirrors OpenClaw `failover-policy.ts`):
///   • Transient (429, 529, 5xx, timeout, network): up to 3 attempts with
///     1 s → 2 s → 4 s backoff.
///   • Permanent (401, 402, 403, 404): fail immediately, no retry.
class FailoverProviderRouter implements ProviderRouter {
  final LlmProvider primary;
  final List<LlmProvider> fallbacks;
  final ConfigManager configManager;

  static const _maxRetries = 3;
  static const _baseDelayMs = 1000;

  FailoverProviderRouter({
    required this.primary,
    this.fallbacks = const [],
    required this.configManager,
  });

  @override
  Future<LlmResponse> chatCompletion(
    LlmRequest request, {
    CancellationToken? cancelToken,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        return await _resolveProvider(request).chatCompletion(
          request,
          cancelToken: cancelToken,
        );
      } catch (e) {
        lastError = e;
        final parsed = parseLlmError(e);

        if (parsed.isPermanent) {
          // No point retrying auth/billing/model-not-found errors.
          _log.warning(
            'Permanent error (${parsed.failoverReason.name}), '
            'skipping retry: ${parsed.friendlyMessage}',
          );
          break;
        }

        if (attempt < _maxRetries - 1) {
          final delayMs = _baseDelayMs * (1 << attempt); // 1s, 2s, 4s
          _log.warning(
            'Transient error (${parsed.failoverReason.name}) on attempt '
            '${attempt + 1}/$_maxRetries — retrying in ${delayMs}ms',
          );
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
    }

    // Primary exhausted — try configured fallback models if any
    _log.warning('Primary model failed after $_maxRetries attempts, trying fallbacks...');
    return _tryFallbacks(request, lastError!, cancelToken: cancelToken);
  }

  @override
  Stream<LlmStreamEvent> chatCompletionStream(
    LlmRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    var hasYieldedContent = false;
    Object? lastError;

    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      if (cancelToken?.isCancelled == true) return;

      try {
        await for (final event in _resolveProvider(request).chatCompletionStream(
          request,
          cancelToken: cancelToken,
        )) {
          if (cancelToken?.isCancelled == true) return;
          if (event.contentDelta != null || event.toolCallDelta != null) {
            hasYieldedContent = true;
          }
          yield event;
        }
        return; // Success
      } catch (e) {
        lastError = e;
        if (hasYieldedContent || cancelToken?.isCancelled == true) {
          _log.severe('Stream failed after yielding content or cancellation, rethrowing.');
          rethrow;
        }

        final parsed = parseLlmError(e);
        if (parsed.isPermanent) {
          _log.warning('Permanent error on stream, skipping retry: $e');
          break;
        }

        if (attempt < _maxRetries - 1) {
          final delayMs = _baseDelayMs * (1 << attempt);
          _log.warning(
            'Transient stream error (${parsed.failoverReason.name}) on attempt '
            '${attempt + 1}/$_maxRetries — retrying in ${delayMs}ms: $e',
          );
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
    }

    // Primary exhausted — try configured fallback models if any
    if (!hasYieldedContent && lastError != null) {
      _log.warning('Primary model stream failed, trying fallbacks...');
      yield* _tryFallbacksStream(request, lastError, cancelToken: cancelToken);
    }
  }

  Stream<LlmStreamEvent> _tryFallbacksStream(
    LlmRequest request,
    Object primaryError, {
    CancellationToken? cancelToken,
  }) async* {
    final config = configManager.config;
    final models = config.modelList;
    if (models.length <= 1) throw primaryError;

    for (var i = 1; i < models.length; i++) {
      if (cancelToken?.isCancelled == true) return;

      final fallbackModel = models[i];
      _log.info('Trying fallback model (stream): ${fallbackModel.modelName}');
      try {
        final fallbackRequest = request.copyWith(
          model: fallbackModel.modelName,
          apiKey: config.resolveApiKey(fallbackModel),
          apiBase: config.resolveApiBase(fallbackModel),
        );

        await for (final event in _resolveProvider(fallbackRequest).chatCompletionStream(
          fallbackRequest,
          cancelToken: cancelToken,
        )) {
          yield event;
        }
        return; // Success with fallback
      } catch (e) {
        final parsed = parseLlmError(e);
        _log.warning(
          'Fallback stream to ${fallbackModel.modelName} failed: '
          '${parsed.friendlyMessage}',
        );
        // Continue to next fallback
      }
    }

    throw primaryError;
  }

  Future<LlmResponse> _tryFallbacks(
    LlmRequest request,
    Object primaryError, {
    CancellationToken? cancelToken,
  }) async {
    final config = configManager.config;
    final models = config.modelList;
    if (models.length <= 1) throw primaryError;

    for (var i = 1; i < models.length; i++) {
      final fallbackModel = models[i];
      _log.info('Trying fallback model: ${fallbackModel.modelName}');

      try {
        final fallbackRequest = request.copyWith(
          model: fallbackModel.model,
          apiKey: config.resolveApiKey(fallbackModel),
          apiBase: config.resolveApiBase(fallbackModel),
        );
        return await _resolveProvider(fallbackRequest).chatCompletion(
          fallbackRequest,
          cancelToken: cancelToken,
        );
      } catch (e) {
        final parsed = parseLlmError(e);
        _log.warning(
          'Fallback ${fallbackModel.modelName} failed '
          '(${parsed.failoverReason.name}): ${parsed.friendlyMessage}',
        );
      }
    }

    throw primaryError;
  }
}
