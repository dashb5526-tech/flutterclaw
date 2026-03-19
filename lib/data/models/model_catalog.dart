import 'package:flutter/material.dart';

class CatalogProvider {
  final String id;
  final String displayName;
  final String description;
  final IconData icon;
  final String signupUrl;
  final String? apiBase;
  final bool hasFreeModels;

  const CatalogProvider({
    required this.id,
    required this.displayName,
    required this.description,
    required this.icon,
    required this.signupUrl,
    this.apiBase,
    this.hasFreeModels = false,
  });
}

class CatalogModel {
  final String id;
  final String displayName;
  final String providerId;
  final bool isFree;
  final int contextWindow;
  final String? description;
  /// Input modalities: 'text', 'image', 'audio'.
  final List<String> input;

  const CatalogModel({
    required this.id,
    required this.displayName,
    required this.providerId,
    required this.isFree,
    required this.contextWindow,
    this.description,
    this.input = const ['text'],
  });

  bool get supportsVision => input.contains('image');
  bool get supportsAudio => input.contains('audio');
}

class ModelCatalog {
  static const providers = <CatalogProvider>[
    CatalogProvider(
      id: 'openrouter',
      displayName: 'OpenRouter',
      description: 'Access 300+ models with one API key. Free models available.',
      icon: Icons.route,
      signupUrl: 'https://openrouter.ai/keys',
      apiBase: 'https://openrouter.ai/api/v1',
      hasFreeModels: true,
    ),
    CatalogProvider(
      id: 'openai',
      displayName: 'OpenAI',
      description: 'GPT-4.1, GPT-4o, o4-mini and more.',
      icon: Icons.auto_awesome,
      signupUrl: 'https://platform.openai.com/api-keys',
      apiBase: 'https://api.openai.com/v1',
    ),
    CatalogProvider(
      id: 'anthropic',
      displayName: 'Anthropic',
      description: 'Claude Sonnet 4.5, Claude Opus 4.6.',
      icon: Icons.psychology,
      signupUrl: 'https://console.anthropic.com/settings/keys',
      apiBase: 'https://api.anthropic.com/v1',
    ),
    CatalogProvider(
      id: 'xai',
      displayName: 'xAI',
      description: 'Grok-3 and Grok-4-fast.',
      icon: Icons.bolt,
      signupUrl: 'https://console.x.ai/',
      apiBase: 'https://api.x.ai/v1',
    ),
    CatalogProvider(
      id: 'ollama',
      displayName: 'Ollama',
      description: 'Run models locally on your machine.',
      icon: Icons.computer,
      signupUrl: 'https://ollama.com/download',
      apiBase: 'http://localhost:11434/v1',
    ),
    CatalogProvider(
      id: 'custom',
      displayName: 'Custom',
      description: 'Any OpenAI-compatible endpoint.',
      icon: Icons.tune,
      signupUrl: '',
    ),
  ];

  static const models = <CatalogModel>[
    // OpenRouter free models (featured) — Free Models Router first (default)
    CatalogModel(
      id: 'openrouter/auto',
      displayName: 'Free Models Router',
      providerId: 'openrouter',
      isFree: true,
      contextWindow: 200000,
      description: 'Auto-selects from available free models',
      input: ['text'],
    ),
    CatalogModel(
      id: 'openrouter/xiaomi/mimo-v2-omni',
      displayName: 'MiMo-V2-Omni',
      providerId: 'openrouter',
      isFree: false,
      contextWindow: 262144,
      description: 'Omni-modal: vision, audio, reasoning',
      input: ['text', 'image', 'audio'],
    ),
    CatalogModel(
      id: 'openrouter/xiaomi/mimo-v2-pro',
      displayName: 'MiMo-V2-Pro',
      providerId: 'openrouter',
      isFree: false,
      contextWindow: 1048576,
      description: 'Agentic, long-horizon planning',
      input: ['text'],
    ),

    // OpenAI
    CatalogModel(
      id: 'gpt-4.1',
      displayName: 'GPT-4.1',
      providerId: 'openai',
      isFree: false,
      contextWindow: 1048576,
      input: ['text', 'image'],
    ),
    CatalogModel(
      id: 'gpt-4o',
      displayName: 'GPT-4o',
      providerId: 'openai',
      isFree: false,
      contextWindow: 128000,
      input: ['text', 'image'],
    ),
    CatalogModel(
      id: 'o4-mini',
      displayName: 'o4-mini',
      providerId: 'openai',
      isFree: false,
      contextWindow: 200000,
      description: 'Fast reasoning model',
      input: ['text', 'image'],
    ),

    // Anthropic
    CatalogModel(
      id: 'claude-sonnet-4-5-20250514',
      displayName: 'Claude Sonnet 4.5',
      providerId: 'anthropic',
      isFree: false,
      contextWindow: 200000,
      input: ['text', 'image'],
    ),
    CatalogModel(
      id: 'claude-opus-4-6-20260301',
      displayName: 'Claude Opus 4.6',
      providerId: 'anthropic',
      isFree: false,
      contextWindow: 200000,
      input: ['text', 'image'],
    ),

    // xAI
    CatalogModel(
      id: 'grok-3',
      displayName: 'Grok-3',
      providerId: 'xai',
      isFree: false,
      contextWindow: 131072,
      input: ['text', 'image'],
    ),
    CatalogModel(
      id: 'grok-4-fast',
      displayName: 'Grok-4 Fast',
      providerId: 'xai',
      isFree: false,
      contextWindow: 131072,
      input: ['text', 'image'],
    ),
  ];

  static CatalogProvider? getProvider(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  static List<CatalogModel> modelsForProvider(String providerId) {
    return models.where((m) => m.providerId == providerId).toList();
  }

  static List<CatalogModel> get freeModels {
    return models.where((m) => m.isFree).toList();
  }

  /// Returns the known input capabilities for a model ID, or null if unknown.
  static List<String>? inputFor(String modelId) {
    for (final m in models) {
      if (m.id == modelId) return m.input;
    }
    return null;
  }

  static String formatContext(int tokens) {
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(0)}M';
    }
    return '${(tokens / 1000).toStringAsFixed(0)}K';
  }
}
