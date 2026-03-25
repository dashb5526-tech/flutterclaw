/// Skill management tools — install from ClawHub, create, list, remove skills.
///
/// Gives the agent the ability to manage skills programmatically, mirroring
/// OpenClaw's gateway `skills.install` / file-based skill creation pattern
/// adapted for FlutterClaw's mobile environment.
library;

import 'dart:convert';

import 'package:flutterclaw/services/skills_service.dart';
import 'package:flutterclaw/tools/registry.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Parse a ClawHub URL or bare slug into the API slug.
///
/// Supported formats:
///   https://clawhub.ai/jaaneek/x-search  → jaaneek/x-search
///   https://clawhub.ai/jaaneek/x-search/ → jaaneek/x-search
///   jaaneek/x-search                     → jaaneek/x-search
///   x-search                             → x-search
String parseClawHubSlug(String urlOrSlug) {
  var s = urlOrSlug.trim();

  // Strip known ClawHub base URLs
  for (final prefix in [
    'https://clawhub.ai/',
    'http://clawhub.ai/',
    'clawhub.ai/',
  ]) {
    if (s.toLowerCase().startsWith(prefix)) {
      s = s.substring(prefix.length);
      break;
    }
  }

  // Strip trailing slash
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);

  // Remove any query string or fragment
  final qIdx = s.indexOf('?');
  if (qIdx >= 0) s = s.substring(0, qIdx);
  final hIdx = s.indexOf('#');
  if (hIdx >= 0) s = s.substring(0, hIdx);

  return s;
}

/// Convert a display name to a filesystem-safe slug.
String _slugify(String name) {
  return name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

// ---------------------------------------------------------------------------
// Pending install cache (for two-step adaptable flow)
// ---------------------------------------------------------------------------

class _PendingInstall {
  final String slug;
  final String originalContent;
  final SkillCompatibilityResult compatibility;
  final DateTime createdAt;

  _PendingInstall({
    required this.slug,
    required this.originalContent,
    required this.compatibility,
  }) : createdAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(createdAt).inMinutes > 10;
}

/// Shared cache so the confirm step doesn't re-download.
final Map<String, _PendingInstall> _pendingInstalls = {};

// ---------------------------------------------------------------------------
// skill_search
// ---------------------------------------------------------------------------

class SkillSearchTool extends Tool {
  final SkillsService skillsService;

  SkillSearchTool({required this.skillsService});

  @override
  String get name => 'skill_search';

  @override
  String get description =>
      'Search ClawHub for available skills to install. '
      'Returns a list of matching skills with name, description, author, '
      'emoji, downloads, and stars.\n\n'
      'Parameters:\n'
      '- query (required): Search query, e.g. "web search", "email", "calendar"';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search query',
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final query = (args['query'] as String? ?? '').trim();
    if (query.isEmpty) return ToolResult.error('query is required');

    final results = await skillsService.searchClawHub(query);

    if (results.isEmpty) {
      return ToolResult.success(jsonEncode({
        'skills': [],
        'message': 'No skills found for "$query". Try a different search term.',
      }));
    }

    return ToolResult.success(jsonEncode({
      'skills': results
          .map((s) => {
                'slug': s.name,
                'description': s.description,
                if (s.author != null) 'author': s.author,
                if (s.emoji != null) 'emoji': s.emoji,
                if (s.version != null) 'version': s.version,
                'downloads': s.downloads,
                'stars': s.stars,
                'install_url': 'https://clawhub.ai/${s.name}',
              })
          .toList(),
      'total': results.length,
      'tip': 'Use skill_install(url: install_url) to install any of these skills.',
    }));
  }
}

// ---------------------------------------------------------------------------
// skill_install
// ---------------------------------------------------------------------------

class SkillInstallTool extends Tool {
  final SkillsService skillsService;

  SkillInstallTool({required this.skillsService});

  @override
  String get name => 'skill_install';

  @override
  String get description =>
      'Install a skill from ClawHub by URL or slug. '
      'The skill is checked for mobile compatibility before installation.\n\n'
      'First call (without confirm): downloads and checks compatibility.\n'
      '- If compatible: installs immediately.\n'
      '- If adaptable: returns both versions — you MUST ask the user which '
      'version to install (original, adapted, or cancel), then call again '
      'with confirm=true.\n'
      '- If incompatible: returns error with reason.\n\n'
      'Second call (with confirm=true): installs the previously downloaded skill.\n\n'
      'Parameters:\n'
      '- url (required): ClawHub URL (e.g. "https://clawhub.ai/jaaneek/x-search") '
      'or bare slug (e.g. "jaaneek/x-search")\n'
      '- confirm (optional): true to finalize an adaptable install\n'
      '- use_adapted (optional): true to install the adapted version, '
      'false for the original (only used with confirm=true)';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'ClawHub URL or slug',
          },
          'confirm': {
            'type': 'boolean',
            'description': 'Finalize a pending adaptable install',
          },
          'use_adapted': {
            'type': 'boolean',
            'description':
                'Install adapted (true) or original (false) version',
          },
        },
        'required': ['url'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final urlOrSlug = args['url'] as String? ?? '';
    if (urlOrSlug.isEmpty) {
      return ToolResult.error('url parameter is required');
    }

    final slug = parseClawHubSlug(urlOrSlug);
    if (slug.isEmpty) {
      return ToolResult.error('Could not parse a valid slug from: $urlOrSlug');
    }

    final confirm = args['confirm'] as bool? ?? false;

    // --- Confirm step (second call) ---
    if (confirm) {
      return _handleConfirm(slug, args);
    }

    // --- First call: download + check compatibility ---
    return _handleFirstCall(slug);
  }

  Future<ToolResult> _handleFirstCall(String slug) async {
    // Download skill content
    final content = await skillsService.downloadSkillContent(slug);
    if (content == null) {
      return ToolResult.error(
        'Could not download skill "$slug" from ClawHub. '
        'Check that the URL/slug is correct and the skill exists.',
      );
    }

    // Check mobile compatibility
    final compat = await skillsService.checkSkillCompatibility(content);

    switch (compat.verdict) {
      case SkillCompatibility.compatible:
        // Install directly
        final dirSlug = slug.contains('/') ? slug.split('/').last : slug;
        final ok =
            await skillsService.installSkillFromContent(dirSlug, content);
        if (!ok) {
          return ToolResult.error('Failed to write skill "$dirSlug" to disk.');
        }
        return ToolResult.success(jsonEncode({
          'status': 'installed',
          'name': dirSlug,
          'message': 'Skill "$dirSlug" installed successfully and is now active.',
        }));

      case SkillCompatibility.adaptable:
        // Cache for confirm step
        final dirSlug = slug.contains('/') ? slug.split('/').last : slug;
        _pendingInstalls[dirSlug] = _PendingInstall(
          slug: dirSlug,
          originalContent: content,
          compatibility: compat,
        );
        return ToolResult.success(jsonEncode({
          'status': 'needs_confirmation',
          'name': dirSlug,
          'reason': compat.reason,
          'message':
              'This skill needs adaptation for mobile. '
              'Ask the user which version to install: '
              'the ORIGINAL (may not work perfectly on mobile), '
              'the ADAPTED version (rewritten for mobile tools), '
              'or CANCEL. '
              'Then call skill_install again with confirm=true and use_adapted=true/false.',
        }));

      case SkillCompatibility.incompatible:
        return ToolResult.success(jsonEncode({
          'status': 'incompatible',
          'name': slug.contains('/') ? slug.split('/').last : slug,
          'reason': compat.reason,
          'message':
              'This skill is incompatible with mobile and cannot be installed. '
              'Reason: ${compat.reason}',
        }));
    }
  }

  Future<ToolResult> _handleConfirm(
      String slug, Map<String, dynamic> args) async {
    final dirSlug = slug.contains('/') ? slug.split('/').last : slug;
    final pending = _pendingInstalls.remove(dirSlug);

    if (pending == null || pending.isExpired) {
      _pendingInstalls.remove(dirSlug);
      return ToolResult.error(
        'No pending install found for "$dirSlug". '
        'Call skill_install without confirm first.',
      );
    }

    final useAdapted = args['use_adapted'] as bool? ?? false;
    final contentToInstall = useAdapted
        ? (pending.compatibility.adaptedContent ?? pending.originalContent)
        : pending.originalContent;

    final ok = await skillsService.installSkillFromContent(
        dirSlug, contentToInstall);
    if (!ok) {
      return ToolResult.error('Failed to write skill "$dirSlug" to disk.');
    }

    final variant = useAdapted ? 'adapted' : 'original';
    return ToolResult.success(jsonEncode({
      'status': 'installed',
      'name': dirSlug,
      'variant': variant,
      'message': 'Skill "$dirSlug" ($variant version) installed successfully.',
    }));
  }
}

// ---------------------------------------------------------------------------
// skill_create
// ---------------------------------------------------------------------------

class SkillCreateTool extends Tool {
  final SkillsService skillsService;

  SkillCreateTool({required this.skillsService});

  @override
  String get name => 'skill_create';

  @override
  String get description =>
      'Create a new custom skill in the agent workspace. '
      'The skill is written as a SKILL.md file with YAML frontmatter and '
      'becomes available immediately.\n\n'
      'Parameters:\n'
      '- name (required): Display name, e.g. "daily-summary"\n'
      '- description (required): Short description of what the skill does\n'
      '- instructions (required): Full skill instructions (Markdown). '
      'These tell the agent how to behave when this skill is active.\n'
      '- emoji (optional): Single emoji for the skill\n'
      '- user_invocable (optional): Whether users can invoke it directly '
      '(default: true)';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Skill display name',
          },
          'description': {
            'type': 'string',
            'description': 'Short description',
          },
          'instructions': {
            'type': 'string',
            'description': 'Full skill instructions (Markdown)',
          },
          'emoji': {
            'type': 'string',
            'description': 'Single emoji',
          },
          'user_invocable': {
            'type': 'boolean',
            'description': 'Whether users can invoke this skill directly',
          },
        },
        'required': ['name', 'description', 'instructions'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final name = (args['name'] as String? ?? '').trim();
    final description = (args['description'] as String? ?? '').trim();
    final instructions = (args['instructions'] as String? ?? '').trim();
    final emoji = (args['emoji'] as String?)?.trim();
    final userInvocable = args['user_invocable'] as bool? ?? true;

    if (name.isEmpty) return ToolResult.error('name is required');
    if (description.isEmpty) {
      return ToolResult.error('description is required');
    }
    if (instructions.isEmpty) {
      return ToolResult.error('instructions is required');
    }

    final slug = _slugify(name);
    if (slug.isEmpty) {
      return ToolResult.error('Could not generate a valid slug from "$name"');
    }

    // Build SKILL.md content
    final buf = StringBuffer();
    buf.writeln('---');
    buf.writeln('name: $slug');
    buf.writeln('description: $description');
    if (emoji != null && emoji.isNotEmpty) buf.writeln('emoji: $emoji');
    if (!userInvocable) buf.writeln('user-invocable: false');
    buf.writeln('---');
    buf.writeln();
    buf.writeln(instructions);

    final ok =
        await skillsService.installSkillFromContent(slug, buf.toString());
    if (!ok) {
      return ToolResult.error('Failed to create skill "$slug".');
    }

    return ToolResult.success(jsonEncode({
      'status': 'created',
      'name': slug,
      'message':
          'Skill "$slug" created successfully and is now active. '
          'It will be included in the system prompt for future messages.',
    }));
  }
}

// ---------------------------------------------------------------------------
// skill_list
// ---------------------------------------------------------------------------

class SkillListTool extends Tool {
  final SkillsService skillsService;

  SkillListTool({required this.skillsService});

  @override
  String get name => 'skill_list';

  @override
  String get description =>
      'List all loaded skills (bundled and workspace). '
      'Returns name, description, emoji, location, and enabled status '
      'for each skill.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final skills = skillsService.skills;
    if (skills.isEmpty) {
      return ToolResult.success(jsonEncode({
        'skills': [],
        'message': 'No skills loaded.',
      }));
    }

    return ToolResult.success(jsonEncode({
      'skills': skills.map((s) => s.toJson()).toList(),
      'total': skills.length,
      'enabled': skills.where((s) => s.enabled).length,
    }));
  }
}

// ---------------------------------------------------------------------------
// skill_remove
// ---------------------------------------------------------------------------

class SkillRemoveTool extends Tool {
  final SkillsService skillsService;

  SkillRemoveTool({required this.skillsService});

  @override
  String get name => 'skill_remove';

  @override
  String get description =>
      'Remove a workspace skill by name. '
      'Bundled skills cannot be removed (only disabled via the UI).\n\n'
      'Parameters:\n'
      '- name (required): The skill name/slug to remove';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Skill name/slug to remove',
          },
        },
        'required': ['name'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final name = (args['name'] as String? ?? '').trim();
    if (name.isEmpty) return ToolResult.error('name is required');

    // Check if skill exists
    final skill = skillsService.skills
        .where((s) => s.name == name)
        .firstOrNull;

    if (skill == null) {
      return ToolResult.error(
          'Skill "$name" not found. Use skill_list to see available skills.');
    }

    if (skill.location != 'workspace') {
      return ToolResult.error(
        'Skill "$name" is a bundled skill and cannot be removed. '
        'It can only be disabled through the UI.',
      );
    }

    await skillsService.removeSkill(name);

    return ToolResult.success(jsonEncode({
      'status': 'removed',
      'name': name,
      'message': 'Skill "$name" has been removed.',
    }));
  }
}
