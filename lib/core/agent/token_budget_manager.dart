/// Token budget management and estimation for FlutterClaw agents.
///
/// Provides centralized token estimation and per-model budget allocation
/// to prevent context window overflow.
library;

import 'dart:convert';

import 'package:logging/logging.dart';

import '../../data/models/config.dart';
import '../../data/models/model_catalog.dart';

final _log = Logger('flutterclaw.token_budget');

/// Manages token budgets and provides estimation utilities.
class TokenBudgetManager {
  /// Estimate tokens for arbitrary content.
  ///
  /// Uses a simple heuristic: ~4 characters per token.
  /// Handles String, List, Map, and other types.
  static int estimateTokens(dynamic content) {
    if (content == null) return 0;

    String text;
    if (content is String) {
      text = content;
    } else if (content is List || content is Map) {
      try {
        text = jsonEncode(content);
      } catch (_) {
        text = content.toString();
      }
    } else {
      text = content.toString();
    }

    // Simple heuristic: 1 token ≈ 4 characters
    return text.length ~/ 4;
  }

  /// Get the context window size for a given model.
  ///
  /// Looks up the model in the catalog and returns its contextWindow.
  /// Returns a default of 200,000 tokens if model not found.
  static int getContextWindow(String modelName, ConfigManager configManager) {
    // First check configured models
    final modelEntry = configManager.config.getModel(modelName);
    if (modelEntry != null) {
      // Try to find in catalog to get context window
      final catalogModel = ModelCatalog.models.firstWhere(
        (m) => m.id == modelEntry.model,
        orElse: () => ModelCatalog.models.first, // Fallback to first model
      );
      return catalogModel.contextWindow;
    }

    // Fallback: search catalog directly by name
    final catalogModel = ModelCatalog.models.firstWhere(
      (m) => m.displayName == modelName || m.id == modelName,
      orElse: () => const CatalogModel(
        id: 'default',
        displayName: 'Default',
        providerId: 'custom',
        isFree: false,
        contextWindow: 200000, // Conservative default
      ),
    );

    return catalogModel.contextWindow;
  }

  /// Check if a tool result is safe to include without truncation.
  ///
  /// A result is "safe" if it's under the max tool result budget
  /// with a 20% buffer for the completion.
  static bool isToolResultSafe(
    String content,
    String modelName,
    ConfigManager configManager,
  ) {
    final estimatedTokens = estimateTokens(content);
    final maxTokens = getMaxToolResultTokens(modelName, configManager);

    return estimatedTokens <= maxTokens;
  }

  /// Get the maximum safe tokens for a single tool result.
  ///
  /// Uses `min(configuredMax, contextWindow * 0.30)` so a single tool result
  /// can never consume more than 30% of the context window regardless of
  /// explicit config, matching OpenClaw's proportional budget strategy.
  static int getMaxToolResultTokens(
    String modelName,
    ConfigManager configManager,
  ) {
    final contextWindow = getContextWindow(modelName, configManager);
    final proportionalMax = (contextWindow * 0.30).toInt();

    final configuredMax =
        configManager.config.agents.defaults.maxToolResultTokens;

    // Clamp: never exceed 30% of the context window, never exceed hard limit
    if (configuredMax > 0) {
      return configuredMax < proportionalMax ? configuredMax : proportionalMax;
    }

    return proportionalMax;
  }

  /// Truncate content to fit within a token limit.
  ///
  /// Uses smart head+tail ratios based on whether the tail contains important
  /// information (errors, JSON endings, summaries).  Matches OpenClaw's
  /// `tool-result-truncation.ts` `hasImportantTail` heuristic:
  ///
  ///  • Normal tail  → 70% head + 10% tail  (same as before)
  ///  • Important tail → 60% head + 25% tail  (preserve errors/JSON/totals)
  static String truncateToTokenLimit(String content, int maxTokens) {
    final estimatedTokens = estimateTokens(content);

    if (estimatedTokens <= maxTokens) {
      return content; // No truncation needed
    }

    // Decide head/tail split based on tail importance
    final importantTail = _hasImportantTail(content);
    final headRatio = importantTail ? 0.60 : 0.70;
    final tailRatio = importantTail ? 0.25 : 0.10;

    final maxChars = maxTokens * 4; // 1 token ≈ 4 chars
    final firstChars = (maxChars * headRatio).toInt();
    final lastChars = (maxChars * tailRatio).toInt();

    final first = content.length > firstChars
        ? content.substring(0, firstChars)
        : content;

    final last = (content.length > lastChars && lastChars > 0)
        ? content.substring(content.length - lastChars)
        : '';

    final omittedChars = content.length - first.length - last.length;
    final tailNote = importantTail ? ' (tail preserved — contains errors/JSON/totals)' : '';
    final truncationMarker = '\n\n'
        '[... TOOL RESULT TRUNCATED$tailNote ...]\n\n'
        'This result was too large (estimated $estimatedTokens tokens, '
        'max $maxTokens tokens).\n'
        'The middle portion was omitted to stay within context limits '
        '(~$omittedChars characters omitted).\n\n'
        'To get the complete data:\n'
        '- Request a smaller date range\n'
        '- Process data in chunks\n'
        '- Use more specific filters\n\n';

    final truncated = first + truncationMarker + last;

    _log.warning(
      'Truncated content: ${content.length} chars → ${truncated.length} chars '
      '($estimatedTokens tokens → ${estimateTokens(truncated)} tokens, '
      'importantTail=$importantTail)',
    );

    return truncated;
  }

  /// Returns true if the last ~2000 characters of [content] appear to contain
  /// important information that should be preserved even when truncating.
  ///
  /// Detects: error messages, JSON/array endings, summary lines, totals, and
  /// result blocks — matching OpenClaw's `hasImportantTail()` heuristic.
  static bool _hasImportantTail(String content) {
    if (content.length < 100) return false;
    final tailLength = content.length < 2000 ? content.length : 2000;
    final tail = content.substring(content.length - tailLength).toLowerCase();
    return tail.contains(RegExp(
      r'error|exception|failed|traceback|'
      r'}\s*$|]\s*$|'          // JSON/array endings
      r'summary|total|result|'
      r'count:|found \d|'
      r'success|completed|done',
      caseSensitive: false,
      multiLine: true,
    ));
  }

  /// Estimate total tokens in a conversation context.
  ///
  /// Sums token estimates for all message contents.
  static int estimateConversationTokens(
    List<dynamic> messages, {
    String? systemPrompt,
  }) {
    var total = 0;

    if (systemPrompt != null) {
      total += estimateTokens(systemPrompt);
    }

    for (final msg in messages) {
      // Handle different message formats
      if (msg is Map) {
        final content = msg['content'];
        total += estimateTokens(content);
      } else {
        // Assume object with content property
        try {
          total += estimateTokens(msg.toString());
        } catch (_) {
          // Skip if can't estimate
        }
      }
    }

    return total;
  }

  /// Get the safe limit for triggering compaction.
  ///
  /// Uses config.agents.defaults.autoCompactThreshold (default: 0.85).
  /// This threshold leaves enough room for the next assistant response
  /// while preventing overflow.
  static int getSafeContextLimit(String modelName, ConfigManager configManager) {
    final contextWindow = getContextWindow(modelName, configManager);
    final threshold =
        configManager.config.agents.defaults.autoCompactThreshold;

    return (contextWindow * threshold).toInt();
  }
}
