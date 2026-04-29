/// Action Center Service — centralized inbox for agent events and results.
///
/// Queues automation results, watcher alerts, and other notifications for
/// user review. Items persist to disk and can be marked as read/dismissed.
///
/// The agent can use this to queue items for later review instead of
/// interrupting the user immediately.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutterclaw/data/models/config.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

final _log = Logger('flutterclaw.action_center');
const _uuid = Uuid();

// ---------------------------------------------------------------------------
// Action Item model
// ---------------------------------------------------------------------------

enum ActionItemType {
  automationResult,
  watcherAlert,
  cronResult,
  notification,
  task,
}

enum ActionItemStatus { unread, read, dismissed }

enum ActionItemPriority { low, normal, high, urgent }

class ActionItem {
  final String id;
  final ActionItemType type;
  final ActionItemPriority priority;
  final String title;
  final String body;
  final String source;
  final DateTime createdAt;
  ActionItemStatus status;
  DateTime? readAt;

  /// Optional: structured data for the item (e.g. rule ID, watcher ID).
  final Map<String, dynamic> metadata;

  ActionItem({
    String? id,
    required this.type,
    this.priority = ActionItemPriority.normal,
    required this.title,
    required this.body,
    this.source = '',
    DateTime? createdAt,
    this.status = ActionItemStatus.unread,
    this.readAt,
    this.metadata = const {},
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'priority': priority.name,
    'title': title,
    'body': body,
    if (source.isNotEmpty) 'source': source,
    'created_at': createdAt.toIso8601String(),
    'status': status.name,
    if (readAt != null) 'read_at': readAt!.toIso8601String(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory ActionItem.fromJson(Map<String, dynamic> json) => ActionItem(
    id: json['id'] as String?,
    type: ActionItemType.values.firstWhere(
      (t) => t.name == (json['type'] as String? ?? 'notification'),
      orElse: () => ActionItemType.notification,
    ),
    priority: ActionItemPriority.values.firstWhere(
      (p) => p.name == (json['priority'] as String? ?? 'normal'),
      orElse: () => ActionItemPriority.normal,
    ),
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    source: json['source'] as String? ?? '',
    createdAt: json['created_at'] != null
        ? DateTime.parse(json['created_at'] as String)
        : null,
    status: ActionItemStatus.values.firstWhere(
      (s) => s.name == (json['status'] as String? ?? 'unread'),
      orElse: () => ActionItemStatus.unread,
    ),
    readAt: json['read_at'] != null
        ? DateTime.parse(json['read_at'] as String)
        : null,
    metadata: (json['metadata'] as Map<String, dynamic>?) ?? {},
  );
}

// ---------------------------------------------------------------------------
// Action Center Service
// ---------------------------------------------------------------------------

class ActionCenterService {
  final ConfigManager configManager;
  final List<ActionItem> _items = [];
  bool _loaded = false;

  /// Maximum items to keep (oldest unread are kept; dismissed are pruned first).
  static const int maxItems = 200;

  ActionCenterService({required this.configManager});

  List<ActionItem> get items => List.unmodifiable(_items);

  int get unreadCount =>
      _items.where((i) => i.status == ActionItemStatus.unread).length;

  /// Load items from disk.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final ws = await configManager.workspacePath;
      final file = File('$ws/action_center/items.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List<dynamic>;
        _items.clear();
        _items.addAll(
          list.map((e) => ActionItem.fromJson(e as Map<String, dynamic>)),
        );
      }
    } catch (e) {
      _log.warning('Failed to load action center items: $e');
    }
  }

  /// Add an item to the action center.
  Future<ActionItem> addItem(ActionItem item) async {
    await load();
    _items.insert(0, item); // newest first
    await _prune();
    await _save();
    _log.info('Action center: added "${item.title}" (${item.type.name})');
    return item;
  }

  /// Mark an item as read.
  Future<void> markRead(String id) async {
    final item = _items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    item.status = ActionItemStatus.read;
    item.readAt = DateTime.now();
    await _save();
  }

  /// Mark all unread items as read.
  Future<void> markAllRead() async {
    final now = DateTime.now();
    for (final item in _items) {
      if (item.status == ActionItemStatus.unread) {
        item.status = ActionItemStatus.read;
        item.readAt = now;
      }
    }
    await _save();
  }

  /// Dismiss (soft-delete) an item.
  Future<void> dismiss(String id) async {
    final item = _items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    item.status = ActionItemStatus.dismissed;
    await _save();
  }

  /// Dismiss all items.
  Future<void> dismissAll() async {
    for (final item in _items) {
      item.status = ActionItemStatus.dismissed;
    }
    await _save();
  }

  /// Get items filtered by status and/or type.
  List<ActionItem> getItems({
    ActionItemStatus? status,
    ActionItemType? type,
    int limit = 50,
  }) {
    var filtered = _items.where((i) {
      if (status != null && i.status != status) return false;
      if (type != null && i.type != type) return false;
      return true;
    });
    return filtered.take(limit).toList();
  }

  Future<void> _prune() async {
    if (_items.length <= maxItems) return;
    // Remove dismissed items first, then oldest read items
    _items.removeWhere((i) => i.status == ActionItemStatus.dismissed);
    if (_items.length > maxItems) {
      // Sort: unread first, then by date descending
      _items.sort((a, b) {
        if (a.status == ActionItemStatus.unread &&
            b.status != ActionItemStatus.unread) {
          return -1;
        }
        if (b.status == ActionItemStatus.unread &&
            a.status != ActionItemStatus.unread) {
          return 1;
        }
        return b.createdAt.compareTo(a.createdAt);
      });
      if (_items.length > maxItems) {
        _items.removeRange(maxItems, _items.length);
      }
    }
  }

  Future<void> _save() async {
    try {
      final ws = await configManager.workspacePath;
      final dir = Directory('$ws/action_center');
      await dir.create(recursive: true);
      final file = File('${dir.path}/items.json');
      final encoder = const JsonEncoder.withIndent('  ');
      await file.writeAsString(
        encoder.convert(_items.map((i) => i.toJson()).toList()),
      );
    } catch (e) {
      _log.warning('Failed to save action center items: $e');
    }
  }
}
