/// MCP server management tools — list, add, and remove MCP servers.
///
/// These tools let the agent configure MCP servers conversationally.
/// Changes are persisted to config.json and the McpClientManager
/// connects/disconnects servers immediately.
library;

import 'dart:convert';

import 'package:flutterclaw/data/models/config.dart';
import 'package:flutterclaw/data/models/mcp_server_config.dart';
import 'package:flutterclaw/services/mcp/mcp_client_manager.dart';
import 'package:flutterclaw/tools/registry.dart';

// ─── mcp_server_list ─────────────────────────────────────────────────────────

class McpServerListTool extends Tool {
  final ConfigManager configManager;
  final McpClientManager mcpManager;

  McpServerListTool({
    required this.configManager,
    required this.mcpManager,
  });

  @override
  String get name => 'mcp_server_list';

  @override
  String get description =>
      'List all configured MCP servers, their connection status, '
      'and how many tools each one exposes. '
      'Use this to check which MCP servers are available before calling their tools.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final servers = configManager.config.mcpServers;
    if (servers.isEmpty) {
      return ToolResult.success(
          'No MCP servers configured. Use mcp_server_add to add one.');
    }

    final items = servers.map((s) {
      final status = mcpManager.getStatus(s.id);
      final tools = mcpManager.getDiscoveredTools(s.id);
      return {
        'id': s.id,
        'name': s.name,
        'enabled': s.enabled,
        'transport': s.transportType.name,
        'url': s.baseUrl,
        'status': status.name,
        'tool_count': tools.length,
        'tools': tools.map((t) => t.name).toList(),
      };
    }).toList();

    return ToolResult.success(jsonEncode(items));
  }
}

// ─── mcp_server_add ──────────────────────────────────────────────────────────

class McpServerAddTool extends Tool {
  final ConfigManager configManager;
  final McpClientManager mcpManager;

  McpServerAddTool({
    required this.configManager,
    required this.mcpManager,
  });

  @override
  String get name => 'mcp_server_add';

  @override
  String get description =>
      'Add a new MCP server so the agent can use its tools. '
      'After adding, the server connects immediately and its tools become available.\n\n'
      'Parameters:\n'
      '- name (required): Human-readable label, e.g. "GitHub", "Notion"\n'
      '- transport (required): "http", "sse", or "stdio"\n'
      '- url (for http/sse): The MCP server URL, e.g. https://mcp.example.com/mcp\n'
      '- token (optional): Bearer token for authentication\n'
      '- command (for stdio): The command to run, e.g. "npx"\n'
      '- args (for stdio): Space-separated arguments, e.g. "-y @modelcontextprotocol/server-github"\n'
      '- env (for stdio): JSON object of environment variables, e.g. {"GITHUB_TOKEN": "ghp_..."}';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Display name for the server (e.g. "GitHub")',
          },
          'transport': {
            'type': 'string',
            'enum': ['http', 'sse', 'stdio'],
            'description': 'Transport type: http, sse, or stdio',
          },
          'url': {
            'type': 'string',
            'description': 'Server URL (required for http/sse transport)',
          },
          'token': {
            'type': 'string',
            'description': 'Bearer token for authentication (optional)',
          },
          'command': {
            'type': 'string',
            'description': 'Command to execute (required for stdio transport)',
          },
          'args': {
            'type': 'string',
            'description': 'Space-separated arguments for the command',
          },
          'env': {
            'type': 'object',
            'description': 'Environment variables as key-value pairs',
            'additionalProperties': {'type': 'string'},
          },
        },
        'required': ['name', 'transport'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final name = args['name'] as String? ?? '';
    final transportStr = args['transport'] as String? ?? 'http';
    final url = args['url'] as String?;
    final token = args['token'] as String?;
    final command = args['command'] as String?;
    final argsStr = args['args'] as String?;
    final envRaw = args['env'] as Map<String, dynamic>?;

    if (name.trim().isEmpty) {
      return ToolResult.error('name is required');
    }

    final transportType = McpTransportType.values.firstWhere(
      (t) => t.name == transportStr,
      orElse: () => McpTransportType.http,
    );

    if ((transportType == McpTransportType.http ||
            transportType == McpTransportType.sse) &&
        (url == null || url.trim().isEmpty)) {
      return ToolResult.error('url is required for $transportStr transport');
    }

    if (transportType == McpTransportType.stdio &&
        (command == null || command.trim().isEmpty)) {
      return ToolResult.error('command is required for stdio transport');
    }

    // Check for duplicate name
    final existing = configManager.config.mcpServers
        .where((s) => s.name.toLowerCase() == name.trim().toLowerCase())
        .firstOrNull;
    if (existing != null) {
      return ToolResult.error(
          'A server named "${name.trim()}" already exists (id: ${existing.id}). '
          'Use mcp_server_remove first if you want to replace it.');
    }

    McpServerEntry entry;
    if (transportType == McpTransportType.stdio) {
      final parsedArgs = argsStr?.trim().isNotEmpty == true
          ? argsStr!.trim().split(RegExp(r'\s+')).toList()
          : null;
      final env = envRaw?.map((k, v) => MapEntry(k, v.toString()));
      entry = McpServerEntry.newStdio(
        name: name.trim(),
        command: command!.trim(),
        args: parsedArgs,
        env: env,
      );
    } else {
      entry = McpServerEntry.newHttp(
        name: name.trim(),
        baseUrl: url!.trim(),
        bearerToken:
            token != null && token.trim().isNotEmpty ? token.trim() : null,
        transportType: transportType,
      );
    }

    // Persist
    final newList = [...configManager.config.mcpServers, entry];
    configManager.update(configManager.config.copyWith(mcpServers: newList));
    await configManager.save();

    // Connect immediately in background
    mcpManager.connectServer(entry).then((_) {
      // Connection result visible via mcp_server_list
    });

    return ToolResult.success(
        jsonEncode({
          'ok': true,
          'id': entry.id,
          'name': entry.name,
          'transport': entry.transportType.name,
          'message':
              'Server "${entry.name}" added. Connecting in the background — '
              'use mcp_server_list to check status and discovered tools.',
        }));
  }
}

// ─── mcp_server_remove ───────────────────────────────────────────────────────

class McpServerRemoveTool extends Tool {
  final ConfigManager configManager;
  final McpClientManager mcpManager;

  McpServerRemoveTool({
    required this.configManager,
    required this.mcpManager,
  });

  @override
  String get name => 'mcp_server_remove';

  @override
  String get description =>
      'Remove an MCP server by name or id. '
      'The server is disconnected and its tools are removed immediately.\n\n'
      'Parameters:\n'
      '- name_or_id (required): Server name (case-insensitive) or exact id';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name_or_id': {
            'type': 'string',
            'description': 'Server name (case-insensitive) or exact server id',
          },
        },
        'required': ['name_or_id'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final query = (args['name_or_id'] as String? ?? '').trim();
    if (query.isEmpty) {
      return ToolResult.error('name_or_id is required');
    }

    final servers = configManager.config.mcpServers;
    final entry = servers.firstWhere(
      (s) =>
          s.id == query ||
          s.name.toLowerCase() == query.toLowerCase(),
      orElse: () => const McpServerEntry(id: '', name: ''),
    );

    if (entry.id.isEmpty) {
      final names = servers.map((s) => '"${s.name}"').join(', ');
      return ToolResult.error(
          'No server found matching "$query". '
          'Configured servers: ${names.isEmpty ? "none" : names}');
    }

    // Disconnect and unregister tools
    await mcpManager.disconnectServer(entry.id);

    // Remove from config
    final newList = servers.where((s) => s.id != entry.id).toList();
    configManager.update(configManager.config.copyWith(mcpServers: newList));
    await configManager.save();

    return ToolResult.success(
        'MCP server "${entry.name}" removed and disconnected.');
  }
}
