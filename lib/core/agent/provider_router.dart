/// Abstract router for LLM provider selection with failover support.
library;

import 'package:flutterclaw/core/providers/provider_interface.dart';
import 'package:flutterclaw/data/models/config.dart';
import 'package:logging/logging.dart';

final _log = Logger('flutterclaw.provider_router');

abstract class ProviderRouter {
  Future<LlmResponse> chatCompletion(LlmRequest request);
  Stream<LlmStreamEvent> chatCompletionStream(LlmRequest request);
}

class SimpleProviderRouter implements ProviderRouter {
  final LlmProvider provider;

  SimpleProviderRouter(this.provider);

  @override
  Future<LlmResponse> chatCompletion(LlmRequest request) =>
      provider.chatCompletion(request);

  @override
  Stream<LlmStreamEvent> chatCompletionStream(LlmRequest request) =>
      provider.chatCompletionStream(request);
}

/// Provider router with automatic failover to fallback models.
class FailoverProviderRouter implements ProviderRouter {
  final LlmProvider primary;
  final List<LlmProvider> fallbacks;
  final ConfigManager configManager;

  FailoverProviderRouter({
    required this.primary,
    this.fallbacks = const [],
    required this.configManager,
  });

  @override
  Future<LlmResponse> chatCompletion(LlmRequest request) async {
    try {
      return await primary.chatCompletion(request);
    } catch (e) {
      _log.warning('Primary model failed: $e, trying fallbacks...');
      return _tryFallbacks(request, e);
    }
  }

  @override
  Stream<LlmStreamEvent> chatCompletionStream(LlmRequest request) {
    return primary.chatCompletionStream(request);
  }

  Future<LlmResponse> _tryFallbacks(LlmRequest request, Object primaryError) async {
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

        final provider = i < fallbacks.length ? fallbacks[i] : primary;
        return await provider.chatCompletion(fallbackRequest);
      } catch (e) {
        _log.warning('Fallback ${fallbackModel.modelName} also failed: $e');
      }
    }

    throw primaryError;
  }
}
