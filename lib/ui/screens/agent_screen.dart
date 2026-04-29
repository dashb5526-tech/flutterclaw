import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutterclaw/core/agent/session_manager.dart';
import 'package:flutterclaw/core/app_providers.dart';
import 'package:flutterclaw/l10n/l10n_extension.dart';
import 'package:flutterclaw/ui/widgets/channel_brand_icon.dart';
import 'package:flutterclaw/services/cron_service.dart';
import 'package:flutterclaw/services/skills_service.dart';

class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  Map<String, String> _files = {};
  bool _loading = true;
  List<SessionMeta> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final configManager = ref.read(configManagerProvider);
    final ws = await configManager.workspacePath;
    final fileNames = [
      'IDENTITY.md',
      'SOUL.md',
      'USER.md',
      'AGENTS.md',
      'TOOLS.md',
      'HEARTBEAT.md',
    ];

    final loaded = <String, String>{};
    for (final name in fileNames) {
      try {
        final file = File('$ws/$name');
        if (await file.exists()) {
          loaded[name] = await file.readAsString();
        }
      } catch (_) {}
    }

    if (mounted) {
      final sessionManager = ref.read(sessionManagerProvider);
      setState(() {
        _files = loaded;
        _sessions = sessionManager.listSessions();
        _loading = false;
      });
    }
  }

  String _parseAgentName() {
    final identity = _files['IDENTITY.md'] ?? '';
    final nameMatch = RegExp(r'(?:Name|name)[:\s]+(.+)').firstMatch(identity);
    return nameMatch?.group(1)?.trim() ?? 'FlutterClaw';
  }

  String _parseAgentEmoji() {
    final identity = _files['IDENTITY.md'] ?? '';
    final emojiMatch = RegExp(
      r'(?:Emoji|emoji)[:\s]+(.+)',
    ).firstMatch(identity);
    var raw = emojiMatch?.group(1)?.trim() ?? '';
    raw = raw.replaceAll('*', '').replaceAll('_', '').trim();
    if (raw.isNotEmpty) return raw;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sessions = _sessions;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.agents)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final agentName = _parseAgentName();
    final agentEmoji = _parseAgentEmoji();

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.agents)),
      body: RefreshIndicator(
        onRefresh: _loadFiles,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Agent identity header
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [colors.primary, colors.tertiary],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Text(
                          agentEmoji.isNotEmpty ? agentEmoji : '🤖',
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            agentName,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            context.l10n.personalAIAssistant,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () => _showFileEditor(context, 'IDENTITY.md'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Workspace files
            _SectionTitle(title: context.l10n.workspaceFiles),
            ..._files.entries.map(
              (e) => _FileCard(
                fileName: e.key,
                preview: _previewText(e.value),
                onTap: () => _showFileEditor(context, e.key),
              ),
            ),

            const SizedBox(height: 20),

            // Sessions
            _SectionTitle(title: context.l10n.sessionsCount(sessions.length)),
            if (sessions.isEmpty)
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.forum_outlined,
                    color: colors.onSurfaceVariant,
                  ),
                  title: Text(context.l10n.noActiveSessions),
                  subtitle: Text(context.l10n.startConversationToCreate),
                ),
              )
            else
              ...sessions.map(
                (s) => Card(
                  child: ListTile(
                    leading: ChannelBrandIcon(
                      channelType: s.channelType,
                      size: 24,
                      iconColor: colors.primary,
                    ),
                    title: Text(s.key),
                    subtitle: Text(
                      '${s.messageCount} msgs | ${s.totalTokens} tokens | ${_timeAgo(s.lastActivity)}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'reset') {
                          final sm = ref.read(sessionManagerProvider);
                          await sm.reset(s.key);
                          await _loadFiles();
                        }
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                          value: 'reset',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text(context.l10n.reset),
                            dense: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            const SizedBox(height: 20),

            // Cron Jobs
            _SectionTitle(
              title: context.l10n.cronJobs,
              trailing: IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _showAddCronJob(context),
              ),
            ),
            _buildCronSection(),

            const SizedBox(height: 20),

            // Skills
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Text(
                    context.l10n.skills,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (ref.read(skillsServiceProvider).isClawHubAuthenticated)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Colors.green.shade800,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'ClawHub',
                            style: TextStyle(
                              color: Colors.green.shade800,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: () => _showClawHubBrowser(context),
                    icon: const Icon(Icons.explore, size: 18),
                    label: Text(context.l10n.browseLabel),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            _buildSkillsSection(),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildCronSection() {
    final cronService = ref.read(cronServiceProvider);
    final jobs = cronService.jobs;

    if (jobs.isEmpty) {
      return Card(
        child: ListTile(
          leading: Icon(
            Icons.schedule,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: Text(context.l10n.noCronJobs),
          subtitle: Text(context.l10n.addScheduledTasks),
        ),
      );
    }

    return Column(
      children: jobs.map((job) {
        final statusColor = switch (job.lastStatus.name) {
          'success' => Colors.green,
          'failed' => Theme.of(context).colorScheme.error,
          'running' => Colors.orange,
          _ => Theme.of(context).colorScheme.onSurfaceVariant,
        };
        return Card(
          child: ListTile(
            onTap: () => _showCronJobDetail(context, job),
            leading: Icon(
              job.enabled ? Icons.timer : Icons.timer_off,
              color: job.enabled ? Colors.green : Colors.grey,
            ),
            title: Text(job.name),
            subtitle: Text(
              '${job.scheduleDisplay} • ${job.lastStatus.name} • '
              'Next: ${job.nextRunAt != null ? _timeAgo(job.nextRunAt!) : "N/A"}',
              style: TextStyle(color: statusColor, fontSize: 12),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (action) async {
                if (action == 'run') {
                  await cronService.runJob(job.id);
                  setState(() {});
                } else if (action == 'toggle') {
                  await cronService.updateJob(job.id, enabled: !job.enabled);
                  setState(() {});
                } else if (action == 'delete') {
                  await cronService.removeJob(job.id);
                  setState(() {});
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  value: 'run',
                  child: ListTile(
                    leading: const Icon(Icons.play_arrow),
                    title: Text(context.l10n.runNow),
                    dense: true,
                  ),
                ),
                PopupMenuItem(
                  value: 'toggle',
                  child: ListTile(
                    leading: Icon(job.enabled ? Icons.pause : Icons.play_arrow),
                    title: Text(
                      job.enabled ? context.l10n.disable : context.l10n.enable,
                    ),
                    dense: true,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline, color: Colors.red),
                    title: Text(
                      context.l10n.delete,
                      style: TextStyle(color: Colors.red),
                    ),
                    dense: true,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSkillsSection() {
    final skillsService = ref.read(skillsServiceProvider);
    final skills = skillsService.skills;

    if (skills.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(
                Icons.extension_outlined,
                size: 40,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.noSkillsInstalled,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.browseClawHubToDiscover,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _showClawHubBrowser(context),
                icon: const Icon(Icons.explore),
                label: Text(context.l10n.browseSkillsButton),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: skills
          .map(
            (skill) => Card(
              child: ListTile(
                leading: Text(
                  skill.emoji ?? '🔧',
                  style: const TextStyle(fontSize: 22),
                ),
                title: Text(skill.name),
                subtitle: Text(
                  skill.description.isNotEmpty
                      ? skill.description
                      : skill.location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        skill.location,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: skill.enabled,
                      onChanged: (val) {
                        skillsService.toggleSkill(skill.name, val);
                        setState(() {});
                      },
                    ),
                  ],
                ),
                onTap: () => _showSkillDetail(context, skill),
                onLongPress: skill.location == 'workspace'
                    ? () => _confirmRemoveSkill(context, skill.name)
                    : null,
              ),
            ),
          )
          .toList(),
    );
  }

  void _showSkillDetail(BuildContext context, Skill skill) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text('${skill.emoji ?? '🔧'} ${skill.name}')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              skill.instructions,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemoveSkill(BuildContext context, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.l10n.removeSkillTitle),
        content: Text(context.l10n.removeSkillConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(context.l10n.remove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final skillsService = ref.read(skillsServiceProvider);
    await skillsService.removeSkill(name);
    setState(() {});
  }

  void _showClawHubBrowser(BuildContext context) {
    final searchCtl = TextEditingController();
    final skillsService = ref.read(skillsServiceProvider);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.clawHubSkills),
            actions: [
              IconButton(
                icon: Icon(
                  skillsService.isClawHubAuthenticated
                      ? Icons.account_circle
                      : Icons.login,
                ),
                tooltip: skillsService.isClawHubAuthenticated
                    ? context.l10n.accountTooltip
                    : context.l10n.loginToClawHub,
                onPressed: () => _showClawHubAuth(context),
              ),
            ],
          ),
          body: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Column(
                children: [
                  // Auth status banner
                  if (!skillsService.isClawHubAuthenticated)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primaryContainer.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              context.l10n.clawHubLoginHint,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonal(
                            onPressed: () => _showClawHubAuth(context),
                            child: Text(context.l10n.login),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: searchCtl,
                      decoration: InputDecoration(
                        hintText: context.l10n.searchSkillsHint,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: () => setSheetState(() {}),
                        ),
                      ),
                      onSubmitted: (_) => setSheetState(() {}),
                    ),
                  ),
                  Expanded(
                    child: FutureBuilder<List<ClawHubSkill>>(
                      future: skillsService.searchClawHub(
                        searchCtl.text.trim().isEmpty
                            ? 'popular'
                            : searchCtl.text.trim(),
                      ),
                      builder: (ctx, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        final results = snapshot.data ?? [];
                        if (results.isEmpty) {
                          return Center(
                            child: Text(context.l10n.noSkillsFound),
                          );
                        }
                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: results.length,
                          itemBuilder: (ctx, i) {
                            final skill = results[i];
                            return Card(
                              child: ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                        .withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Center(
                                    child: Text(
                                      skill.emoji ?? '🔧',
                                      style: const TextStyle(fontSize: 22),
                                    ),
                                  ),
                                ),
                                title: Text(
                                  skill.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    skill.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () =>
                                    _showSkillDetailFromHub(context, skill),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _showClawHubAuth(BuildContext context) {
    final skillsService = ref.read(skillsServiceProvider);

    if (skillsService.isClawHubAuthenticated) {
      // Show account options (logout)
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.l10n.clawHubAccount),
          content: Text(context.l10n.loggedInToClawHub),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () async {
                await skillsService.logoutClawHub();
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(context.l10n.loggedOutFromClawHub)),
                  );
                }
                setState(() {});
              },
              child: Text(context.l10n.logout),
            ),
          ],
        ),
      );
      return;
    }

    // Show login dialog
    final tokenCtl = TextEditingController();
    bool isLoading = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.connectToClawHub,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: tokenCtl,
                decoration: InputDecoration(
                  labelText: context.l10n.apiTokenLabel,
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.key),
                  hintText: context.l10n.pasteClawHubToken,
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    ctx,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.howToGetApiToken,
                            style: Theme.of(ctx).textTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.clawHubApiTokenInstructions,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        if (tokenCtl.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(context.l10n.pleaseEnterApiToken),
                              backgroundColor: Colors.orange,
                            ),
                          );
                          return;
                        }

                        setSheetState(() => isLoading = true);

                        final result = await skillsService.authenticateClawHub(
                          token: tokenCtl.text.trim(),
                        );

                        if (ctx.mounted) {
                          setSheetState(() => isLoading = false);

                          if (result.success) {
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  context.l10n.successfullyConnected,
                                ),
                              ),
                            );
                            setState(() {});
                          } else {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '${context.l10n.connectionFailed}: ${result.error ?? "Invalid token"}',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                child: isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.l10n.connect),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCronJobDetail(BuildContext context, CronJob job) {
    final taskCtl = TextEditingController(text: job.task);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final dirty = taskCtl.text.trim() != job.task.trim();
          final statusColor = switch (job.lastStatus.name) {
            'success' => Colors.green,
            'failed' => colors.error,
            'running' => Colors.orange,
            _ => colors.onSurfaceVariant,
          };

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(job.name, style: theme.textTheme.titleLarge),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.schedule, size: 14),
                      label: Text(
                        job.scheduleDisplay,
                        style: theme.textTheme.labelSmall,
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    Chip(
                      label: Text(
                        job.lastStatus.name,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: statusColor,
                        ),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    if (job.runCount > 0)
                      Chip(
                        avatar: const Icon(Icons.replay, size: 14),
                        label: Text(
                          context.l10n.cronJobRuns(job.runCount),
                          style: theme.textTheme.labelSmall,
                        ),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
                if (job.nextRunAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.nextRunLabel(_timeAgo(job.nextRunAt!)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                if (job.lastError != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      context.l10n.lastErrorLabel(job.lastError!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  context.l10n.taskPrompt,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: taskCtl,
                  maxLines: 8,
                  minLines: 4,
                  onChanged: (_) => setSheetState(() {}),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: context.l10n.cronJobHintText,
                    filled: true,
                    fillColor: colors.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(context.l10n.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: dirty
                          ? () async {
                              final cronService = ref.read(cronServiceProvider);
                              await cronService.updateJob(
                                job.id,
                                task: taskCtl.text.trim(),
                              );
                              if (ctx.mounted) Navigator.pop(ctx);
                              setState(() {});
                            }
                          : null,
                      child: Text(context.l10n.save),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showAddCronJob(BuildContext context) {
    final nameCtl = TextEditingController();
    final taskCtl = TextEditingController();
    int intervalMinutes = 60;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.addCronJob,
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtl,
                decoration: InputDecoration(
                  labelText: context.l10n.jobName,
                  border: OutlineInputBorder(),
                  hintText: context.l10n.dailySummaryExample,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: taskCtl,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: context.l10n.taskPrompt,
                  border: OutlineInputBorder(),
                  hintText: context.l10n.whatShouldAgentDo,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: intervalMinutes,
                decoration: InputDecoration(
                  labelText: context.l10n.interval,
                  border: OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: 5,
                    child: Text(context.l10n.every5Minutes),
                  ),
                  DropdownMenuItem(
                    value: 15,
                    child: Text(context.l10n.every15Minutes),
                  ),
                  DropdownMenuItem(
                    value: 30,
                    child: Text(context.l10n.every30Minutes),
                  ),
                  DropdownMenuItem(
                    value: 60,
                    child: Text(context.l10n.everyHour),
                  ),
                  DropdownMenuItem(
                    value: 360,
                    child: Text(context.l10n.every6Hours),
                  ),
                  DropdownMenuItem(
                    value: 720,
                    child: Text(context.l10n.every12Hours),
                  ),
                  DropdownMenuItem(
                    value: 1440,
                    child: Text(context.l10n.every24Hours),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setSheetState(() => intervalMinutes = v);
                  }
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(context.l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      if (nameCtl.text.trim().isEmpty ||
                          taskCtl.text.trim().isEmpty) {
                        return;
                      }
                      final cronService = ref.read(cronServiceProvider);
                      await cronService.addJob(
                        CronJob(
                          name: nameCtl.text.trim(),
                          task: taskCtl.text.trim(),
                          interval: Duration(minutes: intervalMinutes),
                        ),
                      );
                      if (ctx.mounted) Navigator.pop(ctx);
                      setState(() {});
                    },
                    child: Text(context.l10n.add),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFileEditor(BuildContext context, String fileName) {
    final content = _files[fileName] ?? '';
    final ctl = TextEditingController(text: content);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: Text(fileName),
            actions: [
              TextButton(
                onPressed: () async {
                  final configManager = ref.read(configManagerProvider);
                  final ws = await configManager.workspacePath;
                  await File('$ws/$fileName').writeAsString(ctl.text);
                  // If IDENTITY.md changed, sync name/emoji back into AgentProfile
                  if (fileName == 'IDENTITY.md') {
                    await configManager.syncAgentIdentitiesFromWorkspace();
                    ref.invalidate(activeAgentProvider);
                    ref.invalidate(agentProfilesProvider);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _loadFiles();
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(context.l10n.fileSaved(fileName))),
                    );
                  }
                },
                child: Text(context.l10n.save),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: ctl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _previewText(String content) {
    final lines = content.trim().split('\n');
    final nonEmpty = lines
        .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
        .toList();
    if (nonEmpty.isEmpty) return '(empty)';
    final preview = nonEmpty.take(2).join(' ').trim();
    return preview.length > 80 ? '${preview.substring(0, 80)}...' : preview;
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.isNegative) {
      final abs = diff.abs();
      if (abs.inMinutes < 60) return 'in ${abs.inMinutes}m';
      if (abs.inHours < 24) return 'in ${abs.inHours}h';
      return 'in ${abs.inDays}d';
    }
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _formatNumber(int num) {
    if (num >= 1000000) return '${(num / 1000000).toStringAsFixed(1)}M';
    if (num >= 1000) return '${(num / 1000).toStringAsFixed(1)}k';
    return num.toString();
  }

  void _showSkillDetailFromHub(BuildContext context, ClawHubSkill skill) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        ctx,
                      ).colorScheme.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        skill.emoji ?? '🔧',
                        style: const TextStyle(fontSize: 32),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          skill.name,
                          style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (skill.author != null)
                          Text(
                            'by @${skill.author}',
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (skill.downloads > 0 ||
                  skill.stars > 0 ||
                  skill.version != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    children: [
                      if (skill.downloads > 0)
                        _StatChip(
                          icon: Icons.download,
                          label: _formatNumber(skill.downloads),
                        ),
                      if (skill.downloads > 0 && skill.stars > 0)
                        const SizedBox(width: 8),
                      if (skill.stars > 0)
                        _StatChip(icon: Icons.star, label: '${skill.stars}'),
                      if (skill.version != null) ...[
                        const SizedBox(width: 8),
                        _StatChip(
                          icon: Icons.label,
                          label: 'v${skill.version}',
                        ),
                      ],
                    ],
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Description',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        skill.description,
                        style: Theme.of(ctx).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: () async {
                    final service = ref.read(skillsServiceProvider);

                    // Download content first for compatibility check
                    final content = await service.downloadSkillContent(
                      skill.name,
                    );
                    if (content == null) {
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.l10n.failedToInstallSkill(skill.name),
                            ),
                          ),
                        );
                      }
                      return;
                    }

                    // Check compatibility with mobile
                    final compat = await service.checkSkillCompatibility(
                      content,
                    );

                    if (!ctx.mounted) return;

                    if (compat.verdict == SkillCompatibility.incompatible) {
                      showDialog(
                        context: ctx,
                        builder: (dCtx) => AlertDialog(
                          icon: const Icon(
                            Icons.block,
                            color: Colors.red,
                            size: 32,
                          ),
                          title: Text(context.l10n.incompatibleSkill),
                          content: Text(
                            context.l10n.incompatibleSkillDesc(compat.reason),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx),
                              child: Text(context.l10n.ok),
                            ),
                          ],
                        ),
                      );
                      return;
                    }

                    if (compat.verdict == SkillCompatibility.adaptable) {
                      final userChoice = await showDialog<String>(
                        context: ctx,
                        builder: (dCtx) => AlertDialog(
                          icon: const Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.orange,
                            size: 32,
                          ),
                          title: Text(context.l10n.compatibilityWarning),
                          content: Text(
                            context.l10n.compatibilityWarningDesc(
                              compat.reason,
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx, 'cancel'),
                              child: Text(context.l10n.cancel),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx, 'original'),
                              child: Text(context.l10n.installOriginal),
                            ),
                            FilledButton(
                              onPressed: compat.adaptedContent != null
                                  ? () => Navigator.pop(dCtx, 'adapt')
                                  : null,
                              child: Text(context.l10n.installAdapted),
                            ),
                          ],
                        ),
                      );

                      if (userChoice == null || userChoice == 'cancel') return;

                      bool ok;
                      if (userChoice == 'adapt' &&
                          compat.adaptedContent != null) {
                        ok = await service.installSkillFromContent(
                          skill.name,
                          compat.adaptedContent!,
                        );
                      } else {
                        ok = await service.installSkillFromContent(
                          skill.name,
                          content,
                        );
                      }

                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              ok
                                  ? context.l10n.installedSkill(skill.name)
                                  : context.l10n.failedToInstallSkill(
                                      skill.name,
                                    ),
                            ),
                          ),
                        );
                        if (ok) setState(() {});
                      }
                      return;
                    }

                    // Compatible — install directly
                    final ok = await service.installSkillFromContent(
                      skill.name,
                      content,
                    );
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? context.l10n.installedSkill(skill.name)
                                : context.l10n.failedToInstallSkill(skill.name),
                          ),
                        ),
                      );
                      if (ok) setState(() {});
                    }
                  },
                  icon: const Icon(Icons.download),
                  label: Text(context.l10n.installSkill),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionTitle({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _FileCard extends StatelessWidget {
  final String fileName;
  final String preview;
  final VoidCallback onTap;

  const _FileCard({
    required this.fileName,
    required this.preview,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.description_outlined),
        title: Text(fileName),
        subtitle: Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
