/// Automation Rules Engine for FlutterClaw.
///
/// Defines "if X then do Y" rules that trigger on [EventBus] events.
/// Rules are persisted to the workspace and evaluated against incoming events.
///
/// Pattern follows cron_service.dart: CRUD operations, persistent JSON storage,
/// and background evaluation via EventBus subscription.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutterclaw/core/agent/subagent_registry.dart';
import 'package:flutterclaw/data/models/config.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';

final _log = Logger('flutterclaw.automation');
const _uuid = Uuid();

// ---------------------------------------------------------------------------
// Automation Rule model
// ---------------------------------------------------------------------------

/// Condition that must match for the rule to fire.
class RuleCondition {
  /// Event type to match (e.g. "cron", "webhook", "channelMessage").
  /// Use "*" to match all event types.
  final String eventType;

  /// Source pattern to match (substring match). Empty = match all sources.
  final String sourcePattern;

  /// Payload field to check. Empty = no payload check.
  final String payloadField;

  /// Match operator: "contains", "equals", "regex", "exists".
  final String operator;

  /// Value to compare against (for contains/equals/regex).
  final String value;

  const RuleCondition({
    this.eventType = '*',
    this.sourcePattern = '',
    this.payloadField = '',
    this.operator = 'contains',
    this.value = '',
  });

  factory RuleCondition.fromJson(Map<String, dynamic> json) => RuleCondition(
        eventType: json['event_type'] as String? ?? '*',
        sourcePattern: json['source_pattern'] as String? ?? '',
        payloadField: json['payload_field'] as String? ?? '',
        operator: json['operator'] as String? ?? 'contains',
        value: json['value'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'event_type': eventType,
        if (sourcePattern.isNotEmpty) 'source_pattern': sourcePattern,
        if (payloadField.isNotEmpty) 'payload_field': payloadField,
        'operator': operator,
        if (value.isNotEmpty) 'value': value,
      };

  /// Test whether an event matches this condition.
  bool matches(AgentEvent event) {
    // Check event type.
    if (eventType != '*' && event.type.name != eventType) return false;

    // Check source pattern.
    if (sourcePattern.isNotEmpty &&
        !event.source.toLowerCase().contains(sourcePattern.toLowerCase())) {
      return false;
    }

    // Check payload field.
    if (payloadField.isNotEmpty) {
      final fieldValue = event.payload[payloadField]?.toString() ?? '';
      switch (operator) {
        case 'exists':
          if (!event.payload.containsKey(payloadField)) return false;
        case 'equals':
          if (fieldValue != value) return false;
        case 'regex':
          if (!RegExp(value, caseSensitive: false).hasMatch(fieldValue)) {
            return false;
          }
        case 'contains':
        default:
          if (!fieldValue.toLowerCase().contains(value.toLowerCase())) {
            return false;
          }
      }
    }

    return true;
  }
}

/// An automation rule: condition + action task string.
class AutomationRule {
  final String id;
  final String name;
  final String description;
  final RuleCondition condition;
  final String task; // Task string sent to agent loop when rule fires
  final bool enabled;
  final DateTime createdAt;
  int fireCount;
  DateTime? lastFiredAt;

  /// Optional: ID of another rule to trigger after this one completes (workflow chaining).
  final String? chainRuleId;

  AutomationRule({
    String? id,
    required this.name,
    this.description = '',
    required this.condition,
    required this.task,
    this.enabled = true,
    DateTime? createdAt,
    this.fireCount = 0,
    this.lastFiredAt,
    this.chainRuleId,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  factory AutomationRule.fromJson(Map<String, dynamic> json) => AutomationRule(
        id: json['id'] as String?,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        condition: RuleCondition.fromJson(
          json['condition'] as Map<String, dynamic>? ?? {},
        ),
        task: json['task'] as String,
        enabled: json['enabled'] as bool? ?? true,
        createdAt: json['created_at'] != null
            ? DateTime.parse(json['created_at'] as String)
            : null,
        fireCount: json['fire_count'] as int? ?? 0,
        lastFiredAt: json['last_fired_at'] != null
            ? DateTime.parse(json['last_fired_at'] as String)
            : null,
        chainRuleId: json['chain_rule_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        'condition': condition.toJson(),
        'task': task,
        'enabled': enabled,
        'created_at': createdAt.toIso8601String(),
        'fire_count': fireCount,
        if (lastFiredAt != null) 'last_fired_at': lastFiredAt!.toIso8601String(),
        if (chainRuleId != null) 'chain_rule_id': chainRuleId,
      };
}

// ---------------------------------------------------------------------------
// Automation Service
// ---------------------------------------------------------------------------

class AutomationService {
  final ConfigManager configManager;

  /// Event bus — set before calling [start].
  EventBus? eventBus;

  final List<AutomationRule> _rules = [];
  bool _running = false;

  /// Minimum interval between consecutive firings of the same rule (debounce).
  static const Duration minFireInterval = Duration(seconds: 30);

  /// Maximum workflow chain depth to prevent infinite loops.
  static const int maxChainDepth = 5;

  AutomationService({
    required this.configManager,
  });

  bool get isRunning => _running;
  List<AutomationRule> get rules => List.unmodifiable(_rules);

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _loadRules();
    eventBus?.subscribe(_onEvent);
    _log.info('Automation service started with ${_rules.length} rule(s)');
  }

  Future<void> stop() async {
    _running = false;
    eventBus?.unsubscribe(_onEvent);
    await _saveRules();
    _log.info('Automation service stopped');
  }

  // -------------------------------------------------------------------------
  // CRUD
  // -------------------------------------------------------------------------

  Future<AutomationRule> addRule(AutomationRule rule) async {
    _rules.add(rule);
    await _saveRules();
    _log.info('Added automation rule: ${rule.name} (${rule.id})');
    return rule;
  }

  Future<void> removeRule(String id) async {
    _rules.removeWhere((r) => r.id == id);
    await _saveRules();
    _log.info('Removed automation rule: $id');
  }

  Future<void> updateRule(
    String id, {
    String? name,
    String? description,
    RuleCondition? condition,
    String? task,
    bool? enabled,
    String? chainRuleId,
  }) async {
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx == -1) return;
    final r = _rules[idx];
    _rules[idx] = AutomationRule(
      id: r.id,
      name: name ?? r.name,
      description: description ?? r.description,
      condition: condition ?? r.condition,
      task: task ?? r.task,
      enabled: enabled ?? r.enabled,
      createdAt: r.createdAt,
      fireCount: r.fireCount,
      lastFiredAt: r.lastFiredAt,
      chainRuleId: chainRuleId ?? r.chainRuleId,
    );
    await _saveRules();
  }

  // -------------------------------------------------------------------------
  // Event handler
  // -------------------------------------------------------------------------

  Future<void> _onEvent(AgentEvent event) async {
    if (!_running) return;

    // Don't trigger automation rules from automation events (prevent loops).
    if (event.type == EventType.automation) return;

    final now = DateTime.now();
    for (final rule in List.of(_rules)) {
      if (!rule.enabled) continue;
      if (!rule.condition.matches(event)) continue;

      // Debounce: skip if fired too recently.
      if (rule.lastFiredAt != null &&
          now.difference(rule.lastFiredAt!) < minFireInterval) {
        continue;
      }

      _log.info(
        'Automation rule "${rule.name}" fired by event [${event.type.name}] ${event.source}',
      );

      rule.fireCount++;
      rule.lastFiredAt = now;

      // Publish a meta-event for observability.
      eventBus?.publish(AgentEvent(
        type: EventType.automation,
        source: 'automation:${rule.id}',
        summary: 'Rule "${rule.name}" fired',
        payload: {
          'rule_id': rule.id,
          'trigger_event_id': event.id,
          'trigger_source': event.source,
        },
      ));

      // Execute the task via the agent loop.
      try {
        await SubagentLoopProxy.instance.processMessage(
          'automation:${rule.id}',
          'Automation rule "${rule.name}" triggered.\n'
          'Trigger: [${event.type.name}] ${event.source} — ${event.summary}\n\n'
          'Task: ${rule.task}\n\n'
          'Execute this task completely using available tools.\n'
          'Deliver results via active channel sessions or send_notification.',
        );

        // Workflow chaining: fire the next rule if configured.
        if (rule.chainRuleId != null) {
          await _executeChain(rule.chainRuleId!, rule.id, 1);
        }
      } catch (e) {
        _log.warning('Automation rule "${rule.name}" execution failed: $e');
      }
    }

    await _saveRules();
  }

  // -------------------------------------------------------------------------
  // Workflow chaining
  // -------------------------------------------------------------------------

  Future<void> _executeChain(
    String chainRuleId,
    String previousRuleId,
    int depth,
  ) async {
    if (depth > maxChainDepth) {
      _log.warning(
        'Chain depth limit ($maxChainDepth) reached at rule $chainRuleId — stopping chain',
      );
      return;
    }

    final rule = _rules.where((r) => r.id == chainRuleId).firstOrNull;
    if (rule == null) {
      _log.warning('Chained rule $chainRuleId not found — skipping');
      return;
    }
    if (!rule.enabled) {
      _log.info('Chained rule "${rule.name}" is disabled — skipping');
      return;
    }

    _log.info(
      'Workflow chain: executing "${rule.name}" (depth $depth, after $previousRuleId)',
    );

    rule.fireCount++;
    rule.lastFiredAt = DateTime.now();

    eventBus?.publish(AgentEvent(
      type: EventType.automation,
      source: 'automation:${rule.id}',
      summary: 'Rule "${rule.name}" fired (chained from $previousRuleId)',
      payload: {
        'rule_id': rule.id,
        'chained_from': previousRuleId,
        'chain_depth': depth,
      },
    ));

    try {
      await SubagentLoopProxy.instance.processMessage(
        'automation:${rule.id}',
        'Automation rule "${rule.name}" triggered (workflow chain step $depth).\n'
        'Previous rule: $previousRuleId\n\n'
        'Task: ${rule.task}\n\n'
        'Execute this task completely using available tools.\n'
        'Deliver results via active channel sessions or send_notification.',
      );

      // Continue chain if this rule also has a chain target.
      if (rule.chainRuleId != null) {
        await _executeChain(rule.chainRuleId!, rule.id, depth + 1);
      }
    } catch (e) {
      _log.warning('Chained rule "${rule.name}" execution failed: $e');
    }

    await _saveRules();
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  Future<void> _loadRules() async {
    try {
      final ws = await configManager.workspacePath;
      final file = File('$ws/automation/rules.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        _rules.clear();
        _rules.addAll(
          list.map((e) => AutomationRule.fromJson(e as Map<String, dynamic>)),
        );
      }
    } catch (e) {
      _log.warning('Failed to load automation rules: $e');
    }
  }

  Future<void> _saveRules() async {
    try {
      final ws = await configManager.workspacePath;
      final dir = Directory('$ws/automation');
      await dir.create(recursive: true);
      final file = File('${dir.path}/rules.json');
      final encoder = const JsonEncoder.withIndent('  ');
      await file.writeAsString(
        encoder.convert(_rules.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      _log.warning('Failed to save automation rules: $e');
    }
  }
}
