/// Chat commands matching OpenClaw's slash command system.
///
/// Intercepts messages starting with "/" before sending to the LLM.
library;

import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';

import 'package:flutterclaw/core/agent/agent_loop.dart';
import 'package:flutterclaw/core/agent/provider_router.dart';
import 'package:flutterclaw/core/agent/session_manager.dart';
import 'package:flutterclaw/core/agent/token_budget_manager.dart';
import 'package:flutterclaw/core/providers/provider_interface.dart';
import 'package:flutterclaw/data/models/config.dart';
import 'package:flutterclaw/services/sandbox_service.dart';

final _log = Logger('flutterclaw.chat_commands');

class ChatCommandResult {
  final bool handled;
  final String? response;

  /// When true, the in-app chat should clear (like switching sessions) because
  /// the transcript was reset on disk.
  final bool clearChatUi;

  /// When true, this is a /btw ephemeral response — shown with a distinct
  /// visual style and NOT added to the persistent session transcript.
  final bool isBtw;

  const ChatCommandResult({
    this.handled = false,
    this.response,
    this.clearChatUi = false,
    this.isBtw = false,
  });

  static const notHandled = ChatCommandResult();
}

class ChatCommandHandler {
  final SessionManager sessionManager;
  final ConfigManager configManager;
  final AgentLoop agentLoop;
  final ProviderRouter providerRouter;
  final SandboxService sandboxService;

  ChatCommandHandler({
    required this.sessionManager,
    required this.configManager,
    required this.agentLoop,
    required this.providerRouter,
    required this.sandboxService,
  });

  Future<ChatCommandResult> handle(String sessionKey, String message) async {
    if (!message.startsWith('/')) return ChatCommandResult.notHandled;

    final parts = message.trim().split(RegExp(r'\s+'));
    final command = parts[0].toLowerCase();
    final args = parts.skip(1).toList();

    switch (command) {
      case '/status':
        return _handleStatus(sessionKey);
      case '/new':
      case '/reset':
        return _handleReset(sessionKey);
      case '/compact':
        final instructions = message.trim().replaceFirst(RegExp(r'^/compact\s*', caseSensitive: false), '');
        return _handleCompact(sessionKey, customInstructions: instructions.isEmpty ? null : instructions);
      case '/model':
        return _handleModel(sessionKey, args);
      case '/think':
        return _handleThink(args);
      case '/verbose':
        return _handleVerbose(args);
      case '/usage':
        return _handleUsage(args);
      case '/sh':
        return _handleShell(args);
      case '/export':
        return _handleExport(sessionKey);
      case '/agents':
        final agentArgs = message.trim().replaceFirst(RegExp(r'^/agents\s*', caseSensitive: false), '');
        return _handleAgents(sessionKey, agentArgs.isEmpty ? null : agentArgs);
      case '/context':
        return _handleContext(sessionKey);
      case '/btw':
        final question = message.trim().replaceFirst(RegExp(r'^/btw\s*', caseSensitive: false), '');
        return _handleBtw(sessionKey, question);
      case '/help':
        return _handleHelp();
      default:
        return ChatCommandResult.notHandled;
    }
  }

  Future<ChatCommandResult> _handleStatus(String sessionKey) async {
    final sessions = sessionManager.listSessions();
    final meta =
        sessions.where((s) => s.key == sessionKey).firstOrNull;

    if (meta == null) {
      return const ChatCommandResult(
        handled: true,
        response: 'No active session.',
      );
    }

    final modelName =
        meta.modelOverride ?? configManager.config.agents.defaults.modelName;

    final cacheInfo = StringBuffer();
    if (meta.cacheReadTokens > 0 || meta.cacheWriteTokens > 0) {
      cacheInfo.write(
        '\n- **Cache:** ${meta.cacheReadTokens} read / ${meta.cacheWriteTokens} write',
      );
    }

    return ChatCommandResult(
      handled: true,
      response: '**Session Status**\n\n'
          '- **Session:** ${meta.key}\n'
          '- **Model:** $modelName\n'
          '- **Messages:** ${meta.messageCount}\n'
          '- **Tokens:** ${meta.totalTokens} total '
          '(${meta.inputTokens} in / ${meta.outputTokens} out)'
          '$cacheInfo\n'
          '- **Channel:** ${meta.channelType}\n'
          '- **Last activity:** ${meta.lastActivity.toIso8601String()}',
    );
  }

  Future<ChatCommandResult> _handleReset(String sessionKey) async {
    await sessionManager.reset(sessionKey);
    return const ChatCommandResult(
      handled: true,
      response: 'Session reset. Starting fresh.',
      clearChatUi: true,
    );
  }

  Future<ChatCommandResult> _handleCompact(
    String sessionKey, {
    String? customInstructions,
  }) async {
    final summary = await agentLoop.compactSession(
      sessionKey,
      customInstructions: customInstructions,
    );
    if (summary == null) {
      return const ChatCommandResult(
        handled: true,
        response: 'Nothing to compact (session too short or safeguard active).',
      );
    }
    return ChatCommandResult(
      handled: true,
      response: '**Compacted.** Summary:\n\n$summary',
    );
  }

  Future<ChatCommandResult> _handleModel(
      String sessionKey, List<String> args) async {
    if (args.isEmpty) {
      final current =
          configManager.config.agents.defaults.modelName;
      final models = configManager.config.modelList
          .map((m) => '- ${m.modelName} (`${m.model}`)')
          .join('\n');
      return ChatCommandResult(
        handled: true,
        response: '**Current model:** $current\n\n**Available:**\n$models',
      );
    }

    final modelName = args.join(' ');
    await sessionManager.setModelOverride(sessionKey, modelName);
    return ChatCommandResult(
      handled: true,
      response: 'Model switched to **$modelName** for this session.',
    );
  }

  ChatCommandResult _handleThink(List<String> args) {
    final level = args.isNotEmpty ? args[0] : 'medium';
    return ChatCommandResult(
      handled: true,
      response: 'Thinking level set to **$level**. '
          '(Note: thinking levels depend on model support.)',
    );
  }

  ChatCommandResult _handleVerbose(List<String> args) {
    final mode = args.isNotEmpty ? args[0] : 'on';
    return ChatCommandResult(
      handled: true,
      response: 'Verbose mode: **$mode**.',
    );
  }

  ChatCommandResult _handleUsage(List<String> args) {
    final mode = args.isNotEmpty ? args[0] : 'tokens';
    return ChatCommandResult(
      handled: true,
      response: 'Usage display mode: **$mode**.',
    );
  }

  Future<ChatCommandResult> _handleShell(List<String> args) async {
    if (args.isEmpty) {
      return const ChatCommandResult(
        handled: true,
        response: '**Usage:** `/sh <command>`\n\n'
            'Runs a command in the Alpine Linux sandbox.\n'
            'Example: `/sh uname -a`\n'
            'For network operations: `/sh apk add git` (auto-detects 90s timeout)',
      );
    }

    final command = args.join(' ');

    try {

    // Check if sandbox is ready
    final status = await sandboxService.status();
    if (status['error'] == true) {
      return ChatCommandResult(
        handled: true,
        response: '❌ Sandbox error: ${status['message']}',
      );
    }

    // Auto-provision if needed
    if (status['ready'] != true) {
      final setup = await sandboxService.setup();
      if (setup['error'] == true) {
        return ChatCommandResult(
          handled: true,
          response: '❌ Setup failed: ${setup['message']}',
        );
      }
    }

    // Auto-detect commands that need longer timeouts
    final needsLongTimeout = command.contains('apk add') ||
        command.contains('apk upgrade') ||
        command.contains('pip install') ||
        command.contains('npm install') ||
        command.contains('git clone');
    final timeoutMs = needsLongTimeout ? 90000 : 30000;

    // Execute the command
    final result = await sandboxService.exec(
      command: command,
      timeoutMs: timeoutMs,
    );

    if (result['error'] == true) {
      return ChatCommandResult(
        handled: true,
        response: '❌ Execution failed: ${result['message']}',
      );
    }

    final exitCode = result['exit_code'] ?? -1;
    final stdout = (result['stdout'] as String?) ?? '';
    final stderr = (result['stderr'] as String?) ?? '';
    final timedOut = result['timed_out'] == true;

    // Debug logging
    print('🐛 /sh command: $command');
    print('🐛 exit_code: $exitCode, timed_out: $timedOut');
    print('🐛 stdout length: ${stdout.length}, stderr length: ${stderr.length}');
    if (stdout.isNotEmpty) print('🐛 stdout preview: ${stdout.substring(0, stdout.length > 100 ? 100 : stdout.length)}');
    if (stderr.isNotEmpty) print('🐛 stderr preview: ${stderr.substring(0, stderr.length > 100 ? 100 : stderr.length)}');

    if (timedOut) {
      return const ChatCommandResult(
        handled: true,
        response: '⏱️ Command timed out (>30s).',
      );
    }

    final output = StringBuffer();
    output.writeln('```');
    output.writeln('\$ $command');
    if (stdout.isNotEmpty) output.write(stdout);
    if (stderr.isNotEmpty) {
      if (stdout.isNotEmpty) output.writeln();
      output.write(stderr);
    }
    output.writeln('```');
    output.write('\nExit code: $exitCode');

    return ChatCommandResult(
      handled: true,
      response: output.toString(),
    );
    } catch (e) {
      return ChatCommandResult(
        handled: true,
        response: '❌ Error: $e',
      );
    }
  }

  /// Exports the current session transcript as Markdown and shares it via
  /// the OS share sheet.
  Future<ChatCommandResult> _handleExport(String sessionKey) async {
    try {
      final messages = sessionManager.getContextMessages(sessionKey);
      if (messages.isEmpty) {
        return const ChatCommandResult(
          handled: true,
          response: 'Nothing to export — session is empty.',
        );
      }

      final sessions = sessionManager.listSessions();
      final meta = sessions.where((s) => s.key == sessionKey).firstOrNull;
      final title = meta?.displayName ?? sessionKey;
      final modelName =
          meta?.modelOverride ?? configManager.config.agents.defaults.modelName;

      final buf = StringBuffer();
      buf.writeln('# $title');
      buf.writeln();
      buf.writeln('**Model:** $modelName  ');
      buf.writeln('**Messages:** ${messages.length}  ');
      buf.writeln('**Exported:** ${DateTime.now().toIso8601String()}');
      buf.writeln();
      buf.writeln('---');
      buf.writeln();

      for (final m in messages) {
        final role = switch (m.role) {
          'user' => '**User**',
          'assistant' => '**Assistant**',
          'tool' => '> *Tool result (${m.name ?? 'unknown'})*',
          _ => m.role,
        };
        final content = m.content is String
            ? m.content as String
            : m.content?.toString() ?? '';
        if (content.trim().isEmpty) continue;

        buf.writeln('### $role');
        buf.writeln(content.trim());
        buf.writeln();
      }

      final markdown = buf.toString();
      await Share.share(markdown, subject: title);

      return const ChatCommandResult(
        handled: true,
        response: 'Session exported.',
      );
    } catch (e) {
      return ChatCommandResult(
        handled: true,
        response: 'Export failed: $e',
      );
    }
  }

  /// Lists available agents or switches to a named agent.
  ///
  /// `/agents` → list all agents with their emoji, name, and model.
  /// `/agents switch <name>` → switch active agent (by name or emoji prefix).
  Future<ChatCommandResult> _handleAgents(
    String sessionKey,
    String? subcommand,
  ) async {
    final profiles = configManager.config.agentProfiles;
    final active = configManager.config.activeAgent;

    if (subcommand == null || subcommand.isEmpty) {
      // List all agents
      if (profiles.isEmpty) {
        return const ChatCommandResult(
          handled: true,
          response: 'No agents configured.',
        );
      }
      final lines = profiles.map((a) {
        final activeMarker = a.id == active?.id ? ' ◀ active' : '';
        return '${a.emoji} **${a.name}** — ${a.modelName}$activeMarker';
      }).join('\n');
      return ChatCommandResult(
        handled: true,
        response: '**Agents**\n\n$lines\n\n'
            '_Switch with `/agents switch <name>`_',
      );
    }

    // Switch subcommand
    final parts = subcommand.trim().split(RegExp(r'\s+'));
    if (parts[0].toLowerCase() == 'switch' && parts.length > 1) {
      final query = parts.sublist(1).join(' ').toLowerCase();
      final match = profiles.firstWhere(
        (a) =>
            a.name.toLowerCase().contains(query) ||
            a.emoji.contains(query),
        orElse: () => profiles.first,
      );
      await configManager.switchAgent(match.id);
      return ChatCommandResult(
        handled: true,
        response: 'Switched to ${match.emoji} **${match.name}**.',
      );
    }

    return const ChatCommandResult(
      handled: true,
      response: 'Usage: `/agents` or `/agents switch <name>`',
    );
  }

  /// Shows a breakdown of the current context window usage.
  Future<ChatCommandResult> _handleContext(String sessionKey) async {
    final sessions = sessionManager.listSessions();
    final meta = sessions.where((s) => s.key == sessionKey).firstOrNull;

    if (meta == null) {
      return const ChatCommandResult(
        handled: true,
        response: 'No active session.',
      );
    }

    final modelName =
        meta.modelOverride ?? configManager.config.agents.defaults.modelName;
    final contextWindow =
        TokenBudgetManager.getContextWindow(modelName, configManager);
    final safeLimit =
        TokenBudgetManager.getSafeContextLimit(modelName, configManager);

    final messages = sessionManager.getContextMessages(sessionKey);
    int toolTokens = 0;
    int convTokens = 0;

    for (final m in messages) {
      final t = TokenBudgetManager.estimateTokens(m.content);
      if (m.role == 'tool') {
        toolTokens += t;
      } else {
        convTokens += t;
      }
    }
    final total = convTokens + toolTokens;
    final pct = contextWindow > 0 ? (total * 100 / contextWindow).round() : 0;
    final bar = _contextBar(total, contextWindow);

    return ChatCommandResult(
      handled: true,
      response: '**Context Usage**\n\n'
          '$bar\n\n'
          '- **Conversation:** ~$convTokens tokens\n'
          '- **Tool results:** ~$toolTokens tokens\n'
          '- **Total (est.):** ~$total / $contextWindow tokens ($pct%)\n'
          '- **Auto-compact at:** $safeLimit tokens '
          '(${(safeLimit * 100 / contextWindow).round()}%)\n'
          '- **Model:** $modelName\n\n'
          '_Note: system prompt tokens not counted (estimated separately)._',
    );
  }

  /// Returns a simple ASCII progress bar for context usage.
  String _contextBar(int used, int total) {
    if (total <= 0) return '';
    final pct = (used / total).clamp(0.0, 1.0);
    const width = 20;
    final filled = (pct * width).round();
    final empty = width - filled;
    final bar = '█' * filled + '░' * empty;
    final emoji = pct < 0.60 ? '🟢' : pct < 0.85 ? '🟡' : '🔴';
    return '$emoji `[$bar]` ${(pct * 100).round()}%';
  }

  /// Handles `/btw <question>` — runs the question in an ephemeral side channel
  /// without touching the main session transcript.
  Future<ChatCommandResult> _handleBtw(
    String sessionKey,
    String question,
  ) async {
    if (question.isEmpty) {
      return const ChatCommandResult(
        handled: true,
        response: 'Usage: `/btw <question>`\n\nAsk a quick side question '
            'without adding it to the session context.',
      );
    }

    final defaults = configManager.config.agents.defaults;
    final session = sessionManager.getSession(sessionKey);
    final modelName = session?.modelOverride ?? defaults.modelName;
    final modelEntry = configManager.config.getModel(modelName);

    if (modelEntry == null) {
      return ChatCommandResult(
        handled: true,
        response: 'Error: model "$modelName" not configured.',
      );
    }

    try {
      final systemPrompt = await agentLoop.buildBtwSystemPrompt(sessionKey);
      final cred = configManager.config.providerCredentials[modelEntry.provider];
      final request = LlmRequest(
        model: modelEntry.model,
        apiKey: configManager.config.resolveApiKey(modelEntry),
        apiBase: configManager.config.resolveApiBase(modelEntry),
        messages: [
          LlmMessage(role: 'system', content: systemPrompt),
          LlmMessage(role: 'user', content: question),
        ],
        maxTokens: 1024,
        temperature: defaults.temperature,
        timeoutSeconds: modelEntry.requestTimeout,
        supportsVision: false,
        awsSecretKey: cred?.awsSecretKey,
        awsRegion: cred?.awsRegion,
        awsAuthMode: cred?.awsAuthMode,
      );

      final response = await providerRouter.chatCompletion(request);
      final answer = response.content?.trim() ?? '(no response)';

      _log.fine('/btw answered ${question.length} chars → ${answer.length} chars');
      return ChatCommandResult(
        handled: true,
        response: answer,
        isBtw: true,
      );
    } catch (e) {
      _log.warning('/btw failed: $e');
      return ChatCommandResult(
        handled: true,
        response: 'Error: $e',
      );
    }
  }

  ChatCommandResult _handleHelp() {
    return const ChatCommandResult(
      handled: true,
      response: '**Chat Commands**\n\n'
          '- `/status` -- session info (model, tokens, cost)\n'
          '- `/new` or `/reset` -- reset the session\n'
          '- `/compact` -- compress session context\n'
          '- `/model [name]` -- view or switch model\n'
          '- `/think <level>` -- off|low|medium|high\n'
          '- `/verbose on|off` -- toggle verbose mode\n'
          '- `/usage off|tokens|full` -- usage footer mode\n'
          '- `/export` -- export session as Markdown (share sheet)\n'
          '- `/agents [switch <name>]` -- list or switch agents\n'
          '- `/context` -- context window usage breakdown\n'
          '- `/btw <question>` -- quick side question (no context pollution)\n'
          '- `/sh <command>` -- run command in Alpine sandbox\n'
          '- `/help` -- show this help',
    );
  }
}
