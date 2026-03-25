/// McpProxyTool — a Tool that delegates execution to an external MCP server.
///
/// One instance is created per MCP tool per server. The tool name is
/// namespaced as `mcp_{serverName}_{toolName}` to avoid collisions.
library;

import 'package:flutterclaw/services/mcp/mcp_client_manager.dart';
import 'package:flutterclaw/tools/registry.dart';

class McpProxyTool extends Tool {
  final String serverId;
  final String serverName;
  final String toolName;
  final String toolDescription;
  final Map<String, dynamic> inputSchema;
  final McpClientManager manager;

  McpProxyTool({
    required this.serverId,
    required this.serverName,
    required this.toolName,
    required this.toolDescription,
    required this.inputSchema,
    required this.manager,
  });

  @override
  String get name => 'mcp_${sanitizeName(serverName)}_$toolName';

  @override
  String get description => '[$serverName] $toolDescription';

  @override
  Map<String, dynamic> get parameters => inputSchema;

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    try {
      return await manager.callTool(serverId, toolName, args);
    } catch (e) {
      return ToolResult.error(
          'MCP tool "$toolName" on server "$serverName" failed: $e');
    }
  }

  /// Sanitize a name for use in a tool name identifier.
  /// Keeps only lowercase alphanumeric characters and underscores.
  static String sanitizeName(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
}
