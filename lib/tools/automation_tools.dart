/// Automation rules CRUD tools.
///
/// Ports the "if X then do Y" rules engine: automation_create / automation_list /
/// automation_delete / automation_update. Rules fire when matching events arrive
/// on the EventBus.
library;

import 'dart:convert';

import 'package:flutterclaw/services/automation_service.dart';
import 'package:flutterclaw/tools/registry.dart';

// ---------------------------------------------------------------------------
// automation_create
// ---------------------------------------------------------------------------

class AutomationCreateTool extends Tool {
  final AutomationService automationService;

  AutomationCreateTool({required this.automationService});

  @override
  String get name => 'automation_create';

  @override
  String get description =>
      'Create an automation rule that fires when a matching event occurs.\n\n'
      'Event types: cron, heartbeat, geofence, watcher, webhook, channelMessage, custom.\n'
      'Use "*" for event_type to match all events.\n\n'
      'Condition operators (for payload_field matching):\n'
      '  • contains — field value contains the value (case-insensitive)\n'
      '  • equals — exact match\n'
      '  • regex — regex match (case-insensitive)\n'
      '  • exists — field exists in payload (value ignored)\n\n'
      'Examples:\n'
      '  • "When a webhook arrives from Stripe, summarize the event and notify me"\n'
      '    → event_type: "webhook", source_pattern: "stripe"\n'
      '  • "When a channel message mentions \'urgent\', escalate"\n'
      '    → event_type: "channelMessage", payload_field: "text", operator: "contains", value: "urgent"\n'
      '  • "When any cron job fires, log it"\n'
      '    → event_type: "cron"\n\n'
      'The task string is the instruction the agent executes when the rule fires. '
      'Always end the task with "then call send_notification with the result".';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Short human-readable name for the rule',
          },
          'description': {
            'type': 'string',
            'description': 'Optional longer description of what the rule does',
          },
          'event_type': {
            'type': 'string',
            'description':
                'Event type to match: cron, heartbeat, geofence, watcher, '
                    'webhook, channelMessage, custom, or "*" for all',
            'default': '*',
          },
          'source_pattern': {
            'type': 'string',
            'description':
                'Substring to match against the event source (case-insensitive). '
                    'Leave empty to match all sources.',
          },
          'payload_field': {
            'type': 'string',
            'description':
                'Payload field to check. Leave empty to skip payload matching.',
          },
          'operator': {
            'type': 'string',
            'enum': ['contains', 'equals', 'regex', 'exists'],
            'description': 'Match operator for the payload field',
            'default': 'contains',
          },
          'value': {
            'type': 'string',
            'description':
                'Value to compare against (for contains/equals/regex)',
          },
          'task': {
            'type': 'string',
            'description':
                'Instructions the agent executes when the rule fires. '
                    'Include all context needed and end with '
                    '"then call send_notification with the result".',
          },
          'chain_rule_id': {
            'type': 'string',
            'description':
                'Optional: ID of another automation rule to trigger after this '
                    'one completes (workflow chaining). Max chain depth: 5.',
          },
        },
        'required': ['name', 'task'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final ruleName = (args['name'] as String?)?.trim() ?? '';
    final task = (args['task'] as String?)?.trim() ?? '';

    if (ruleName.isEmpty) return ToolResult.error('name is required');
    if (task.isEmpty) return ToolResult.error('task is required');

    final eventType = (args['event_type'] as String?)?.trim() ?? '*';
    final sourcePattern = (args['source_pattern'] as String?)?.trim() ?? '';
    final payloadField = (args['payload_field'] as String?)?.trim() ?? '';
    final operator = (args['operator'] as String?)?.trim() ?? 'contains';
    final value = (args['value'] as String?)?.trim() ?? '';
    final description = (args['description'] as String?)?.trim() ?? '';
    final chainRuleId = (args['chain_rule_id'] as String?)?.trim();

    // Validate operator
    const validOperators = ['contains', 'equals', 'regex', 'exists'];
    if (!validOperators.contains(operator)) {
      return ToolResult.error(
        'Invalid operator "$operator". Must be one of: ${validOperators.join(", ")}',
      );
    }

    // Validate regex if used
    if (operator == 'regex' && value.isNotEmpty) {
      try {
        RegExp(value);
      } catch (e) {
        return ToolResult.error('Invalid regex "$value": $e');
      }
    }

    final condition = RuleCondition(
      eventType: eventType,
      sourcePattern: sourcePattern,
      payloadField: payloadField,
      operator: operator,
      value: value,
    );

    final rule = AutomationRule(
      name: ruleName,
      description: description,
      condition: condition,
      task: task,
      chainRuleId: chainRuleId,
    );

    final stored = await automationService.addRule(rule);

    return ToolResult.success(jsonEncode({
      'ok': true,
      'id': stored.id,
      'name': stored.name,
      'condition': {
        'event_type': eventType,
        if (sourcePattern.isNotEmpty) 'source_pattern': sourcePattern,
        if (payloadField.isNotEmpty) 'payload_field': payloadField,
        'operator': operator,
        if (value.isNotEmpty) 'value': value,
      },
      'message':
          'Automation rule "${stored.name}" created. It will fire when a matching '
              '${eventType == "*" ? "any" : eventType} event arrives.',
    }));
  }
}

// ---------------------------------------------------------------------------
// automation_list
// ---------------------------------------------------------------------------

class AutomationListTool extends Tool {
  final AutomationService automationService;

  AutomationListTool({required this.automationService});

  @override
  String get name => 'automation_list';

  @override
  String get description =>
      'List all automation rules with their conditions, status, and fire history.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final rules = automationService.rules;

    final list = rules.map((r) {
      return {
        'id': r.id,
        'name': r.name,
        if (r.description.isNotEmpty) 'description': r.description,
        'condition': r.condition.toJson(),
        'task': r.task.length > 120 ? '${r.task.substring(0, 120)}…' : r.task,
        'enabled': r.enabled,
        'fire_count': r.fireCount,
        'last_fired': r.lastFiredAt?.toIso8601String(),
      };
    }).toList();

    return ToolResult.success(jsonEncode({
      'ok': true,
      'count': list.length,
      'rules': list,
    }));
  }
}

// ---------------------------------------------------------------------------
// automation_delete
// ---------------------------------------------------------------------------

class AutomationDeleteTool extends Tool {
  final AutomationService automationService;

  AutomationDeleteTool({required this.automationService});

  @override
  String get name => 'automation_delete';

  @override
  String get description =>
      'Delete an automation rule by id. Use automation_list to find the id first.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'The id of the automation rule to delete',
          },
        },
        'required': ['id'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final id = (args['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return ToolResult.error('id is required');

    final existing =
        automationService.rules.where((r) => r.id == id).firstOrNull;
    if (existing == null) {
      return ToolResult.error('No automation rule found with id "$id"');
    }

    await automationService.removeRule(id);

    return ToolResult.success(jsonEncode({
      'ok': true,
      'deleted_id': id,
      'deleted_name': existing.name,
      'message': 'Automation rule "${existing.name}" deleted.',
    }));
  }
}

// ---------------------------------------------------------------------------
// automation_update
// ---------------------------------------------------------------------------

class AutomationUpdateTool extends Tool {
  final AutomationService automationService;

  AutomationUpdateTool({required this.automationService});

  @override
  String get name => 'automation_update';

  @override
  String get description =>
      'Enable, disable, or update the task/condition of an existing automation rule. '
      'Use automation_list to find the id first.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'The id of the automation rule to update',
          },
          'name': {
            'type': 'string',
            'description': 'New name for the rule',
          },
          'enabled': {
            'type': 'boolean',
            'description': 'true to enable, false to disable',
          },
          'task': {
            'type': 'string',
            'description': 'New task instructions to replace the existing ones',
          },
          'event_type': {
            'type': 'string',
            'description': 'New event type to match',
          },
          'source_pattern': {
            'type': 'string',
            'description': 'New source pattern to match',
          },
          'payload_field': {
            'type': 'string',
            'description': 'New payload field to check',
          },
          'operator': {
            'type': 'string',
            'enum': ['contains', 'equals', 'regex', 'exists'],
            'description': 'New match operator',
          },
          'value': {
            'type': 'string',
            'description': 'New value to compare against',
          },
          'chain_rule_id': {
            'type': 'string',
            'description':
                'ID of another rule to trigger after this one completes (workflow chaining). '
                    'Pass empty string to remove chaining.',
          },
        },
        'required': ['id'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final id = (args['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return ToolResult.error('id is required');

    final existing =
        automationService.rules.where((r) => r.id == id).firstOrNull;
    if (existing == null) {
      return ToolResult.error('No automation rule found with id "$id"');
    }

    final newName = (args['name'] as String?)?.trim();
    final enabled = args['enabled'] as bool?;
    final task = (args['task'] as String?)?.trim();
    final chainRuleIdRaw = args['chain_rule_id'] as String?;
    final chainRuleId = chainRuleIdRaw?.trim();

    // Build updated condition if any condition fields are provided
    RuleCondition? newCondition;
    final eventType = args['event_type'] as String?;
    final sourcePattern = args['source_pattern'] as String?;
    final payloadField = args['payload_field'] as String?;
    final operator = args['operator'] as String?;
    final value = args['value'] as String?;

    if (eventType != null ||
        sourcePattern != null ||
        payloadField != null ||
        operator != null ||
        value != null) {
      // Validate operator if provided
      if (operator != null) {
        const validOperators = ['contains', 'equals', 'regex', 'exists'];
        if (!validOperators.contains(operator)) {
          return ToolResult.error(
            'Invalid operator "$operator". Must be one of: ${validOperators.join(", ")}',
          );
        }
      }

      newCondition = RuleCondition(
        eventType: eventType ?? existing.condition.eventType,
        sourcePattern: sourcePattern ?? existing.condition.sourcePattern,
        payloadField: payloadField ?? existing.condition.payloadField,
        operator: operator ?? existing.condition.operator,
        value: value ?? existing.condition.value,
      );
    }

    if (newName == null &&
        enabled == null &&
        task == null &&
        newCondition == null &&
        chainRuleId == null) {
      return ToolResult.error(
        'Provide at least one field to update: name, enabled, task, condition fields, or chain_rule_id',
      );
    }

    await automationService.updateRule(
      id,
      name: newName,
      enabled: enabled,
      task: task,
      condition: newCondition,
      chainRuleId: chainRuleId?.isEmpty == true ? null : chainRuleId,
    );

    return ToolResult.success(jsonEncode({
      'ok': true,
      'id': id,
      'name': newName ?? existing.name,
      'enabled': enabled ?? existing.enabled,
      'message': 'Automation rule "${newName ?? existing.name}" updated.',
    }));
  }
}
