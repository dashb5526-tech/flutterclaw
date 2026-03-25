library;

import 'package:live_activities/live_activities.dart';
import 'package:logging/logging.dart';

final _log = Logger('flutterclaw.live_activity');

/// Service for managing iOS Live Activities via the live_activities package.
/// The WidgetKit extension (FlutterClawWidgets) reads data from the shared
/// UserDefaults (app group: group.ai.flutterclaw) written by this plugin.
class LiveActivityService {
  static final _plugin = LiveActivities();
  static String? _activityId;
  static bool _initialized = false;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _plugin.init(appGroupId: 'group.ai.flutterclaw');
    _initialized = true;
  }

  /// Start a Live Activity for the gateway
  static Future<void> startActivity({
    required String host,
    required int port,
    required String model,
  }) async {
    try {
      await _ensureInitialized();
      await _plugin.endAllActivities();
      final data = _buildData(
        host: host,
        port: port,
        model: model,
        isRunning: true,
        status: 'running',
        tokensProcessed: 0,
        sessionCount: 0,
        uptimeSeconds: 0,
      );
      final id = 'gateway_${DateTime.now().millisecondsSinceEpoch}';
      _activityId = await _plugin.createActivity(id, data);
      _log.info('Live Activity started: $_activityId');
    } catch (e) {
      _log.warning('Failed to start Live Activity: $e');
    }
  }

  /// Start a Live Activity showing error state
  static Future<void> startActivityWithError({
    required String host,
    required int port,
    required String model,
    required String errorMessage,
  }) async {
    try {
      await _ensureInitialized();
      await _plugin.endAllActivities();
      final data = _buildData(
        host: host,
        port: port,
        model: model,
        isRunning: false,
        status: 'error',
        tokensProcessed: 0,
        sessionCount: 0,
        uptimeSeconds: 0,
        errorMessage: errorMessage,
      );
      final id = 'gateway_${DateTime.now().millisecondsSinceEpoch}';
      _activityId = await _plugin.createActivity(id, data);
      _log.info('Live Activity started (error state): $_activityId');
    } catch (e) {
      _log.warning('Failed to start Live Activity (error state): $e');
    }
  }

  /// Update an active Live Activity
  static Future<void> updateActivity({
    required bool isRunning,
    required String status,
    required int tokensProcessed,
    required String model,
    required int sessionCount,
    DateTime? lastMessageAt,
    required int uptimeSeconds,
    String? errorMessage,
  }) async {
    if (_activityId == null) return;
    try {
      final data = _buildData(
        host: '',
        port: 0,
        model: model,
        isRunning: isRunning,
        status: status,
        tokensProcessed: tokensProcessed,
        sessionCount: sessionCount,
        uptimeSeconds: uptimeSeconds,
        lastMessageAt: lastMessageAt,
        errorMessage: errorMessage,
      );
      await _plugin.updateActivity(_activityId!, data);
    } catch (e) {
      _log.warning('Failed to update Live Activity: $e');
    }
  }

  /// End the current Live Activity
  static Future<void> endActivity() async {
    if (_activityId == null) return;
    try {
      await _plugin.endActivity(_activityId!);
      _log.info('Live Activity ended: $_activityId');
      _activityId = null;
    } catch (e) {
      _log.warning('Failed to end Live Activity: $e');
    }
  }

  /// Check if a Live Activity is currently active
  static Future<bool> isActivityActive() async {
    return _activityId != null;
  }

  /// End all Live Activities
  static Future<void> endAllActivities() async {
    try {
      await _plugin.endAllActivities();
      _activityId = null;
    } catch (e) {
      _log.warning('Failed to end all Live Activities: $e');
    }
  }

  /// Build the data map whose keys match what GatewayLiveActivity.swift reads
  /// via UserDefaults using attributes.prefixedKey("KEY").
  static Map<String, dynamic> _buildData({
    required String host,
    required int port,
    required String model,
    required bool isRunning,
    required String status,
    required int tokensProcessed,
    required int sessionCount,
    required int uptimeSeconds,
    DateTime? lastMessageAt,
    String? errorMessage,
  }) {
    return <String, dynamic>{
      'host': host,
      'port': port.toString(),
      'model': model,
      'isRunning': isRunning ? 'true' : 'false',
      'status': status,
      'tokensProcessed': tokensProcessed.toString(),
      'sessionCount': sessionCount.toString(),
      'uptimeSeconds': uptimeSeconds.toString(),
      'lastMessageAt': lastMessageAt != null
          ? lastMessageAt.millisecondsSinceEpoch.toString()
          : '0',
      'errorMessage': errorMessage ?? '',
    };
  }
}
