/// Onboarding page to enable the Android Accessibility Service and
/// "Display over other apps" overlay permission for UI automation.
/// Only shown on Android. Allows the user to enable or skip.
library;

import 'package:flutter/material.dart';
import 'package:flutterclaw/services/overlay_service.dart';
import 'package:flutterclaw/services/ui_automation_service.dart';

class AccessibilityPage extends StatefulWidget {
  final UiAutomationService service;
  final OverlayService overlayService;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  const AccessibilityPage({
    super.key,
    required this.service,
    required this.overlayService,
    required this.onContinue,
    required this.onSkip,
  });

  @override
  State<AccessibilityPage> createState() => _AccessibilityPageState();
}

class _AccessibilityPageState extends State<AccessibilityPage>
    with WidgetsBindingObserver {
  bool? _accessibilityGranted;
  bool? _overlayGranted;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _checkPermissions();
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      _checkPermissions();
    });
  }

  Future<void> _checkPermissions() async {
    if (_checking) return;
    setState(() => _checking = true);
    final accResult = await widget.service.checkPermission();
    final overlayResult = await widget.overlayService.checkPermission();
    if (mounted) {
      setState(() {
        _accessibilityGranted = accResult['granted'] as bool? ?? false;
        _overlayGranted = overlayResult;
        _checking = false;
      });
    }
  }

  Future<void> _openAccessibilitySettings() async {
    await widget.service.requestPermission();
  }

  Future<void> _openOverlaySettings() async {
    await widget.overlayService.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accGranted = _accessibilityGranted ?? false;
    final overlayGranted = _overlayGranted ?? false;
    final allGranted = accGranted && overlayGranted;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      children: [
        // Icon
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: (allGranted ? colors.primary : colors.surfaceContainerHighest)
                  .withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              allGranted ? Icons.accessibility_new : Icons.touch_app_outlined,
              size: 36,
              color: allGranted ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 24),

        // Title
        Text(
          'Android Permissions',
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
          'Two permissions are needed for the full experience. '
          'You can skip this and enable them later in Settings.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),

        // 1. Accessibility Service
        _PermissionCard(
          icon: Icons.touch_app_outlined,
          title: 'Accessibility Service',
          subtitle: 'Allows tapping, swiping, typing, and reading screen content',
          granted: accGranted,
          checking: _checking,
          onEnable: _openAccessibilitySettings,
        ),
        const SizedBox(height: 12),

        // 2. Overlay permission
        _PermissionCard(
          icon: Icons.picture_in_picture_alt_outlined,
          title: 'Display Over Other Apps',
          subtitle: 'Shows a floating status chip so you can see what the agent is doing',
          granted: overlayGranted,
          checking: _checking,
          onEnable: _openOverlaySettings,
        ),
        const SizedBox(height: 28),

        // Continue / Skip
        if (allGranted || accGranted)
          FilledButton.icon(
            onPressed: widget.onContinue,
            icon: const Icon(Icons.check),
            label: const Text('Continue'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.primary,
            ),
          ),
        if (!accGranted) ...[
          FilledButton.icon(
            onPressed: _openAccessibilitySettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Accessibility Settings'),
          ),
          const SizedBox(height: 12),
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
      ],
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool granted;
  final bool checking;
  final VoidCallback onEnable;

  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.checking,
    required this.onEnable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

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
            icon,
            color: granted ? colors.primary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: granted ? colors.onPrimaryContainer : colors.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: granted
                        ? colors.onPrimaryContainer.withValues(alpha: 0.7)
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (checking)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (granted)
            Icon(Icons.check_circle, color: colors.primary)
          else
            TextButton(
              onPressed: onEnable,
              child: const Text('Enable'),
            ),
        ],
      ),
    );
  }
}
