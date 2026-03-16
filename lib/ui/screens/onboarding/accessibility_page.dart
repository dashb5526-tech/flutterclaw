/// Onboarding page to enable the Android Accessibility Service for UI automation.
/// Only shown on Android. Allows the user to enable or skip.
library;

import 'package:flutter/material.dart';
import 'package:flutterclaw/services/ui_automation_service.dart';

class AccessibilityPage extends StatefulWidget {
  final UiAutomationService service;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  const AccessibilityPage({
    super.key,
    required this.service,
    required this.onContinue,
    required this.onSkip,
  });

  @override
  State<AccessibilityPage> createState() => _AccessibilityPageState();
}

class _AccessibilityPageState extends State<AccessibilityPage>
    with WidgetsBindingObserver {
  bool? _granted;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check when the user returns from the Settings app. Use a short delay so
  // the system has time to update the accessibility list; then re-check again
  // once more in case the list updates asynchronously.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _checkPermission();
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      _checkPermission();
    });
  }

  Future<void> _checkPermission() async {
    if (_checking) return;
    setState(() => _checking = true);
    final r = await widget.service.checkPermission();
    if (mounted) {
      setState(() {
        _granted = r['granted'] as bool? ?? false;
        _checking = false;
      });
    }
  }

  Future<void> _openSettings() async {
    await widget.service.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final granted = _granted ?? false;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        // Icon
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: (granted ? colors.primary : colors.surfaceContainerHighest)
                  .withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              granted ? Icons.accessibility_new : Icons.touch_app_outlined,
              size: 36,
              color: granted ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Title
        Text(
          'UI Automation',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),

        // Description
        Text(
          'FlutterClaw can control your screen on your behalf — tapping buttons, '
          'filling forms, scrolling, and automating repetitive tasks across any app.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'This requires enabling the Accessibility Service in Android Settings. '
          'You can skip this and enable it later.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),

        // Status indicator
        _StatusTile(granted: granted, checking: _checking),
        const SizedBox(height: 24),

        // Enable button
        if (!granted)
          FilledButton.icon(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Accessibility Settings'),
          ),
        if (granted)
          FilledButton.icon(
            onPressed: widget.onContinue,
            icon: const Icon(Icons.check),
            label: const Text('Continue'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.primary,
            ),
          ),
        const SizedBox(height: 12),

        // Skip
        if (!granted)
          Center(
            child: TextButton(
              onPressed: widget.onSkip,
              child: Text(
                'Skip for now',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }
}

class _StatusTile extends StatelessWidget {
  final bool granted;
  final bool checking;

  const _StatusTile({required this.granted, required this.checking});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    if (checking) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
            ),
            const SizedBox(width: 12),
            Text('Checking permission…', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (granted
                ? colors.primaryContainer
                : colors.surfaceContainerHighest)
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            granted ? Icons.check_circle : Icons.radio_button_unchecked,
            color: granted ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              granted
                  ? 'Accessibility Service is enabled'
                  : 'Accessibility Service is not enabled',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: granted ? colors.onPrimaryContainer : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
