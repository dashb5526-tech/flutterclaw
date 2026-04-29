/// Device tools for FlutterClaw.
///
/// Mobile-native tools: device status, notifications,
/// scheduled reminders, clipboard, and share sheet.
library;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutterclaw/services/notification_service.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timezone/timezone.dart' as tz;
import 'registry.dart';

class DeviceStatusTool extends Tool {
  @override
  String get name => 'device_status';

  @override
  String get description =>
      'Return device status: battery level, charging state, connectivity.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    const mock = '''
battery_level: 85
charging: true
connectivity: wifi
''';
    return ToolResult.success(mock.trim());
  }
}

/// Sends a local push notification to the user's device.
///
/// Use this whenever you want to alert the user: cron job results,
/// reminders, important events, or any proactive update.
class SendNotificationTool extends Tool {
  final NotificationService _notificationService;
  final String Function()? _sessionKeyGetter;

  SendNotificationTool({
    required NotificationService notificationService,
    String Function()? sessionKeyGetter,
  })  : _notificationService = notificationService,
        _sessionKeyGetter = sessionKeyGetter;

  @override
  String get name => 'send_notification';

  @override
  String get description =>
      'Send a push notification to the user\'s device. '
      'Use this to alert the user about cron job results, reminders, '
      'completed tasks, or any important event.\n\n'
      'Parameters:\n'
      '- title: Short notification title\n'
      '- body: The message body (keep under 200 chars)\n'
      '- session_key: (optional) The session key of the conversation the user '
      'should open when tapping the notification. '
      'If you received a session_key in your task prompt, pass it here so the '
      'user lands directly on your response.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Notification title.',
          },
          'body': {
            'type': 'string',
            'description': 'Notification body text. Keep concise (under 200 chars).',
          },
          'session_key': {
            'type': 'string',
            'description':
                'Session key to open when the notification is tapped '
                '(e.g. "cron:abc123"). Use the session_key from your task prompt.',
          },
        },
        'required': ['title', 'body'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final title = (args['title'] as String?)?.trim();
    final body = (args['body'] as String?)?.trim();

    if (title == null || title.isEmpty) {
      return ToolResult.error('title is required');
    }
    if (body == null || body.isEmpty) {
      return ToolResult.error('body is required');
    }

    try {
      await _notificationService.initialize();
      // Prefer explicit session_key from args (e.g. cron job passing its own key),
      // fall back to the active webchat session via the getter.
      final explicitKey = (args['session_key'] as String?)?.trim();
      final sessionKey = (explicitKey != null && explicitKey.isNotEmpty)
          ? explicitKey
          : _sessionKeyGetter?.call();
      await _notificationService.showMessageNotification(
        sessionKey ?? 'agent',
        title,
        body,
        payload: sessionKey,
      );
      return ToolResult.success('Notification sent: $title');
    } catch (e) {
      return ToolResult.error('Failed to send notification: $e');
    }
  }
}

/// Schedules a local notification (reminder) at a specific date/time.
class ScheduleReminderTool extends Tool {
  final NotificationService _notificationService;

  ScheduleReminderTool({required NotificationService notificationService})
      : _notificationService = notificationService;

  static final _plugin = FlutterLocalNotificationsPlugin();

  @override
  String get name => 'schedule_reminder';

  @override
  String get description =>
      'Schedule a local notification to appear at a specific date and time. '
      'Use this for reminders, alarms, and timed alerts. '
      'Returns the reminder ID needed to cancel it later.\n\n'
      'Note: iOS supports up to 64 scheduled notifications.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'Reminder title.'},
          'body': {'type': 'string', 'description': 'Reminder message body.'},
          'datetime': {
            'type': 'string',
            'description':
                'ISO 8601 datetime when the reminder should fire, e.g. "2025-03-14T09:00:00".',
          },
          'id': {
            'type': 'integer',
            'description':
                'Optional integer ID (1000–99999). Auto-generated if omitted.',
          },
        },
        'required': ['title', 'body', 'datetime'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final title = (args['title'] as String?)?.trim() ?? '';
    final body = (args['body'] as String?)?.trim() ?? '';
    final datetimeStr = (args['datetime'] as String?)?.trim() ?? '';

    if (title.isEmpty) return ToolResult.error('title is required');
    if (body.isEmpty) return ToolResult.error('body is required');
    if (datetimeStr.isEmpty) return ToolResult.error('datetime is required');

    final scheduledDate = DateTime.tryParse(datetimeStr);
    if (scheduledDate == null) {
      return ToolResult.error('Invalid datetime format. Use ISO 8601.');
    }
    if (scheduledDate.isBefore(DateTime.now())) {
      return ToolResult.error('datetime must be in the future');
    }

    final id = (args['id'] as num?)?.toInt() ??
        (1000 + scheduledDate.millisecondsSinceEpoch.abs() % 90000);

    try {
      await _notificationService.initialize();
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledDate, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'flutterclaw_reminders',
            'Reminders',
            channelDescription: 'Scheduled reminders from the AI agent',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );

      return ToolResult.success(
        'Reminder scheduled. id=$id, fires_at=$datetimeStr',
      );
    } catch (e) {
      return ToolResult.error('Failed to schedule reminder: $e');
    }
  }
}

/// Cancels a previously scheduled reminder by ID.
class CancelReminderTool extends Tool {
  final NotificationService _notificationService;

  CancelReminderTool({required NotificationService notificationService})
      : _notificationService = notificationService;

  @override
  String get name => 'cancel_reminder';

  @override
  String get description =>
      'Cancel a previously scheduled reminder by its numeric ID. '
      'Use the ID returned by schedule_reminder.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'integer',
            'description': 'The reminder ID to cancel.',
          },
        },
        'required': ['id'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final id = (args['id'] as num?)?.toInt();
    if (id == null) return ToolResult.error('id is required');

    try {
      await _notificationService.cancelNotification(id);
      return ToolResult.success('Reminder $id cancelled.');
    } catch (e) {
      return ToolResult.error('Failed to cancel reminder: $e');
    }
  }
}

/// Reads text from the system clipboard.
class ClipboardReadTool extends Tool {
  @override
  String get name => 'clipboard_read';

  @override
  String get description =>
      'Read the current text content of the system clipboard. '
      'Returns the clipboard text, or an empty string if clipboard is empty.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {},
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.isEmpty) return ToolResult.success('(clipboard is empty)');
      return ToolResult.success(text);
    } catch (e) {
      return ToolResult.error('Failed to read clipboard: $e');
    }
  }
}

/// Writes text to the system clipboard.
class ClipboardWriteTool extends Tool {
  @override
  String get name => 'clipboard_write';

  @override
  String get description =>
      'Write text to the system clipboard so the user can paste it anywhere.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'The text to copy to clipboard.',
          },
        },
        'required': ['text'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final text = args['text'] as String? ?? '';
    if (text.isEmpty) return ToolResult.error('text is required');

    try {
      await Clipboard.setData(ClipboardData(text: text));
      return ToolResult.success('Copied to clipboard (${text.length} chars).');
    } catch (e) {
      return ToolResult.error('Failed to write to clipboard: $e');
    }
  }
}

/// Opens the native share sheet to share text with other apps.
class ShareContentTool extends Tool {
  @override
  String get name => 'share_content';

  @override
  String get description =>
      'Open the native share sheet so the user can share text to other apps '
      '(Messages, Mail, Notes, social media, etc.). '
      'Returns whether the share was completed or dismissed.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'The text to share.',
          },
          'subject': {
            'type': 'string',
            'description': 'Optional subject line (used by Mail and similar apps).',
          },
        },
        'required': ['text'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final text = (args['text'] as String?)?.trim() ?? '';
    final subject = (args['subject'] as String?)?.trim();

    if (text.isEmpty) return ToolResult.error('text is required');

    try {
      final result = await Share.share(
        text,
        subject: subject,
      );
      final status = switch (result.status) {
        ShareResultStatus.success => 'shared',
        ShareResultStatus.dismissed => 'dismissed',
        ShareResultStatus.unavailable => 'unavailable',
      };
      return ToolResult.success('Share result: $status');
    } catch (e) {
      return ToolResult.error('Failed to share: $e');
    }
  }
}
