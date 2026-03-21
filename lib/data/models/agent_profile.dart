/// Agent profile model for multi-agent support.
///
/// Each AgentProfile represents a unique AI agent with its own configuration,
/// personality, and isolated workspace.
library;

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Represents a configured agent with its own identity and settings.
class AgentProfile {
  /// Unique identifier for this agent
  final String id;

  /// Human-readable name (e.g., "Assistant", "Coder", "Writer")
  final String name;

  /// Emoji representing the agent (e.g., "🤖", "💻", "✍️")
  final String emoji;

  /// Relative workspace path (e.g., "agents/{uuid}/")
  final String workspacePath;

  // Model configuration
  /// Which LLM model this agent uses
  final String modelName;

  /// Sampling temperature (0.0 - 2.0)
  final double temperature;

  /// Maximum tokens per request
  final int maxTokens;

  /// Maximum tool iteration loops
  final int maxToolIterations;

  /// Restrict file operations to workspace
  final bool restrictToWorkspace;

  // Personality/behavior
  /// User-defined personality descriptor (e.g., "friendly", "formal", "snarky")
  final String? vibe;

  /// Optional custom system prompt override
  final String? systemPromptOverride;

  // Metadata
  /// When this agent was created
  final DateTime createdAt;

  /// Last time this agent was used
  final DateTime lastUsedAt;

  /// Whether this is the default agent
  final bool isDefault;

  const AgentProfile({
    required this.id,
    required this.name,
    required this.emoji,
    required this.workspacePath,
    required this.modelName,
    this.temperature = 0.7,
    this.maxTokens = 8192,
    this.maxToolIterations = 40,
    this.restrictToWorkspace = true,
    this.vibe,
    this.systemPromptOverride,
    required this.createdAt,
    required this.lastUsedAt,
    this.isDefault = false,
  });

  /// Create a new agent with generated ID and workspace path
  factory AgentProfile.create({
    required String name,
    required String emoji,
    required String modelName,
    double temperature = 0.7,
    int maxTokens = 8192,
    int maxToolIterations = 20,
    bool restrictToWorkspace = true,
    String? vibe,
    String? systemPromptOverride,
    bool isDefault = false,
  }) {
    final id = _uuid.v4();
    final now = DateTime.now();
    return AgentProfile(
      id: id,
      name: name,
      emoji: emoji,
      workspacePath: 'agents/$id',
      modelName: modelName,
      temperature: temperature,
      maxTokens: maxTokens,
      maxToolIterations: maxToolIterations,
      restrictToWorkspace: restrictToWorkspace,
      vibe: vibe,
      systemPromptOverride: systemPromptOverride,
      createdAt: now,
      lastUsedAt: now,
      isDefault: isDefault,
    );
  }

  /// Deserialize from JSON
  factory AgentProfile.fromJson(Map<String, dynamic> json) => AgentProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        emoji: json['emoji'] as String? ?? '🤖',
        workspacePath: json['workspace_path'] as String,
        modelName: json['model_name'] as String,
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        maxTokens: json['max_tokens'] as int? ?? 8192,
        maxToolIterations: json['max_tool_iterations'] as int? ?? 20,
        restrictToWorkspace: json['restrict_to_workspace'] as bool? ?? true,
        vibe: json['vibe'] as String?,
        systemPromptOverride: json['system_prompt_override'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        lastUsedAt: DateTime.parse(json['last_used_at'] as String),
        isDefault: json['is_default'] as bool? ?? false,
      );

  /// Serialize to JSON
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'workspace_path': workspacePath,
        'model_name': modelName,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'max_tool_iterations': maxToolIterations,
        'restrict_to_workspace': restrictToWorkspace,
        if (vibe != null) 'vibe': vibe,
        if (systemPromptOverride != null)
          'system_prompt_override': systemPromptOverride,
        'created_at': createdAt.toIso8601String(),
        'last_used_at': lastUsedAt.toIso8601String(),
        'is_default': isDefault,
      };

  /// Create a copy with updated fields
  AgentProfile copyWith({
    String? name,
    String? emoji,
    String? modelName,
    double? temperature,
    int? maxTokens,
    int? maxToolIterations,
    bool? restrictToWorkspace,
    String? vibe,
    String? systemPromptOverride,
    DateTime? lastUsedAt,
    bool? isDefault,
  }) =>
      AgentProfile(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        workspacePath: workspacePath,
        modelName: modelName ?? this.modelName,
        temperature: temperature ?? this.temperature,
        maxTokens: maxTokens ?? this.maxTokens,
        maxToolIterations: maxToolIterations ?? this.maxToolIterations,
        restrictToWorkspace: restrictToWorkspace ?? this.restrictToWorkspace,
        vibe: vibe ?? this.vibe,
        systemPromptOverride: systemPromptOverride ?? this.systemPromptOverride,
        createdAt: createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        isDefault: isDefault ?? this.isDefault,
      );

  @override
  String toString() => 'AgentProfile(id: $id, name: $name, emoji: $emoji)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentProfile &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
