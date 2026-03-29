import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutterclaw/channels/channel_interface.dart';
import 'package:flutterclaw/services/pairing_service.dart';
import 'package:logging/logging.dart';

const _apiBase = 'https://api.telegram.org/bot';
const _fileBase = 'https://api.telegram.org/file/bot';
const _type = 'telegram';

class TelegramChannelAdapter implements ChannelAdapter {
  TelegramChannelAdapter({
    required this.token,
    this.allowedUserIds = const [],
    this.botUsername,
    this.dmPolicy = 'pairing',
    this.pairingService,
    this.chatCommandHandler,
    this.typingMode = 'instant',
  }) : _dio = Dio(BaseOptions(
          baseUrl: '$_apiBase$token',
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 60),
        ));

  final String token;
  final List<String> allowedUserIds;
  final String? botUsername;
  final String dmPolicy;
  final PairingService? pairingService;

  /// Typing indicator mode: 'never' | 'instant' | 'thinking' | 'message'
  final String typingMode;
  final Dio _dio;
  final _log = Logger('TelegramChannelAdapter');

  /// Optional: handler for slash commands (returns response text or null to pass through)
  final Future<String?> Function(String sessionKey, String command)?
      chatCommandHandler;

  MessageHandler? _handler;
  bool _running = false;
  int _lastUpdateId = 0;
  int _backoffSeconds = 1;
  final Map<String, Timer> _typingTimers = {};

  /// Per-chat processing queues — ensures messages within the same chat are
  /// handled in order while different chats can be processed concurrently.
  /// This prevents the poll loop from blocking on long-running tool execution.
  final Map<String, Future<void>> _chatQueues = {};

  static const _maxBackoffSeconds = 300;

  @override
  String get type => _type;

  @override
  bool get isConnected => _running;

  @override
  Future<void> start(MessageHandler handler) async {
    if (_running) {
      _log.warning('Telegram adapter already running');
      return;
    }
    _handler = handler;
    _running = true;
    _backoffSeconds = 1;

    await _registerCommands();
    unawaited(_pollLoop());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _handler = null;
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
  }

  // -- Typing indicators --

  Future<void> sendTyping(String chatId) async {
    try {
      await _dio.post('/sendChatAction', data: {
        'chat_id': chatId,
        'action': 'typing',
      });
    } catch (_) {}
  }

  void startTyping(String chatId) {
    _typingTimers[chatId]?.cancel();
    sendTyping(chatId);
    _typingTimers[chatId] = Timer.periodic(
      const Duration(seconds: 5),
      (_) => sendTyping(chatId),
    );
  }

  void stopTyping(String chatId) {
    _typingTimers[chatId]?.cancel();
    _typingTimers.remove(chatId);
  }

  // -- Status reactions --

  /// Sets a single emoji reaction on a message.
  /// Uses the Telegram Bot API `setMessageReaction` (Bot API 7.0+).
  /// Silently ignored on older bots or if not supported.
  Future<void> _setReaction(String chatId, int messageId, String emoji) async {
    try {
      await _dio.post('/setMessageReaction', data: {
        'chat_id': chatId,
        'message_id': messageId,
        'reaction': [
          {'type': 'emoji', 'emoji': emoji}
        ],
        'is_big': false,
      });
    } catch (_) {
      // Reactions not supported or bot lacks permission — silently ignore
    }
  }

  /// Clears all reactions from a message by sending an empty reaction list.
  Future<void> _clearReaction(String chatId, int messageId) async {
    try {
      await _dio.post('/setMessageReaction', data: {
        'chat_id': chatId,
        'message_id': messageId,
        'reaction': <dynamic>[],
      });
    } catch (_) {}
  }

  // -- Slash command registration --

  Future<void> _registerCommands() async {
    try {
      await _dio.post('/setMyCommands', data: {
        'commands': [
          {'command': 'status', 'description': 'Session status (model, tokens)'},
          {'command': 'new', 'description': 'Start a new session'},
          {'command': 'compact', 'description': 'Compact session context'},
          {'command': 'model', 'description': 'View or switch model'},
          {'command': 'think', 'description': 'Set thinking level'},
          {'command': 'help', 'description': 'Show available commands'},
        ],
      });
      _log.info('Registered Telegram slash commands');
    } catch (e) {
      _log.warning('Failed to register Telegram commands: $e');
    }
  }

  // -- Poll loop --

  Future<void> _pollLoop() async {
    while (_running && _handler != null) {
      try {
        final updates = await _getUpdates();
        _backoffSeconds = 1;

        for (final u in updates) {
          final updateId = u['update_id'] as int;
          if (updateId > _lastUpdateId) _lastUpdateId = updateId;

          final message = u['message'] as Map<String, dynamic>?;
          if (message == null) continue;

          final chat = message['chat'] as Map<String, dynamic>?;
          final from = message['from'] as Map<String, dynamic>?;
          if (chat == null || from == null) continue;

          final chatId = chat['id'];
          if (chatId == null) continue;
          final chatIdStr = chatId.toString();

          final isGroup = (chat['type'] as String?) == 'group' ||
              (chat['type'] as String?) == 'supergroup';
          final senderId = (from['id'] ?? '').toString();
          final senderName = _extractSenderName(from);
          final text = _extractText(message);
          final photoUrls = _extractPhotoUrls(message);

          // Download voice/audio bytes if present
          final audioData = await _extractAudioBytes(message);

          // Skip empty messages (no text, no photo, no audio)
          if (text.isEmpty && photoUrls.isEmpty && audioData == null) continue;

          if (isGroup && botUsername != null) {
            final mention = '@${botUsername!.replaceFirst('@', '')}';
            if (!text.toLowerCase().contains(mention.toLowerCase())) continue;
          }

          // -- DM policy check (non-group only) --
          if (!isGroup) {
            final allowed = await _checkDmPolicy(senderId, senderName, chatIdStr);
            if (!allowed) continue;
          }

          // -- Slash command handling --
          if (text.startsWith('/') && chatCommandHandler != null) {
            final sessionKey = '$_type:$chatIdStr';
            final response = await chatCommandHandler!(sessionKey, text);
            if (response != null) {
              await sendMessage(OutgoingMessage(
                channelType: _type,
                chatId: chatIdStr,
                text: response,
              ));
              continue;
            }
          }

          final replyTo = message['reply_to_message'] != null
              ? (message['reply_to_message'] as Map<String, dynamic>)['message_id'] as int?
              : null;

          final incoming = IncomingMessage(
            channelType: _type,
            senderId: senderId,
            senderName: senderName,
            chatId: chatIdStr,
            text: text,
            isGroup: isGroup,
            replyToMessageId: replyTo?.toString(),
            timestamp: DateTime.now(),
            photoUrls: photoUrls.isNotEmpty ? photoUrls : null,
            audioBytes: audioData?.$1,
            audioFormat: audioData?.$2,
            audioDuration: audioData?.$3,
          );

          // Process the message asynchronously so the poll loop can continue
          // fetching new updates. Per-chat ordering is preserved via _chatQueues
          // so messages within the same chat are still handled sequentially.
          final incomingMsgId = message['message_id'] as int?;
          _enqueueHandler(chatIdStr, incoming, incomingMsgId);
        }
      } catch (e, st) {
        _log.warning('Telegram poll error, reconnecting in $_backoffSeconds s', e, st);
        await Future<void>.delayed(Duration(seconds: _backoffSeconds));
        _backoffSeconds = min(_backoffSeconds * 2, _maxBackoffSeconds);
      }
    }
  }

  /// Enqueue a handler invocation for [chatId], preserving per-chat ordering
  /// while allowing different chats to be processed concurrently.
  void _enqueueHandler(
    String chatId,
    IncomingMessage incoming,
    int? incomingMsgId,
  ) {
    final previous = _chatQueues[chatId] ?? Future<void>.value();
    _chatQueues[chatId] = previous.then((_) async {
      if (typingMode == 'instant') startTyping(chatId);
      if (incomingMsgId != null) {
        await _setReaction(chatId, incomingMsgId, '⏳');
      }
      try {
        await _handler!(incoming);
        if (incomingMsgId != null) {
          await _setReaction(chatId, incomingMsgId, '✅');
        }
      } catch (e, st) {
        _log.severe('Handler error processing Telegram message', e, st);
        if (incomingMsgId != null) {
          await _clearReaction(chatId, incomingMsgId);
        }
      } finally {
        stopTyping(chatId);
      }
    });
  }

  /// Check DM policy. Returns true if the sender is allowed.
  Future<bool> _checkDmPolicy(
    String senderId,
    String senderName,
    String chatId,
  ) async {
    switch (dmPolicy) {
      case 'open':
        return true;

      case 'disabled':
        return false;

      case 'allowlist':
        if (allowedUserIds.isEmpty) return true;
        return allowedUserIds.contains(senderId);

      case 'pairing':
      default:
        // Static allowlist takes priority
        if (allowedUserIds.isNotEmpty && allowedUserIds.contains(senderId)) {
          return true;
        }

        if (pairingService == null) return true;

        final approved = await pairingService!.isApproved(_type, senderId);
        if (approved) return true;

        // Generate pairing code
        final code = await pairingService!.createRequest(
          _type,
          senderId,
          senderName,
        );

        if (code != null) {
          await sendMessage(OutgoingMessage(
            channelType: _type,
            chatId: chatId,
            text: 'Hi! To use this bot, send this pairing code to the owner:\n\n'
                '$code\n\n'
                'The code expires in 1 hour.',
          ));
        }

        return false;
    }
  }

  // -- Helpers --

  List<String> _extractPhotoUrls(Map<String, dynamic> message) {
    final urls = <String>[];
    final photo = message['photo'] as List<dynamic>?;
    if (photo != null && photo.isNotEmpty) {
      final largest = photo.last as Map<String, dynamic>;
      final fileId = largest['file_id'] as String?;
      if (fileId != null) urls.add('telegram:file:$fileId');
    }
    final doc = message['document'] as Map<String, dynamic>?;
    if (doc != null) {
      final fid = doc['file_id'] as String?;
      if (fid != null) urls.add('telegram:file:$fid');
    }
    return urls;
  }

  /// Download audio bytes from a voice/audio message.
  ///
  /// Returns a (bytes, format, durationSeconds) tuple or null if not an audio
  /// message or if download fails.
  Future<(Uint8List, String, int?)?> _extractAudioBytes(
    Map<String, dynamic> message,
  ) async {
    // Voice messages (PTT) — OGG/Opus
    final voice = message['voice'] as Map<String, dynamic>?;
    if (voice != null) {
      final fileId = voice['file_id'] as String?;
      final duration = voice['duration'] as int?;
      if (fileId != null) {
        final bytes = await _downloadFile(fileId);
        if (bytes != null) return (bytes, 'ogg', duration);
      }
    }

    // Audio file messages
    final audio = message['audio'] as Map<String, dynamic>?;
    if (audio != null) {
      final fileId = audio['file_id'] as String?;
      final duration = audio['duration'] as int?;
      final mimeType = audio['mime_type'] as String? ?? '';
      final ext = _mimeToExt(mimeType);
      if (fileId != null) {
        final bytes = await _downloadFile(fileId);
        if (bytes != null) return (bytes, ext, duration);
      }
    }

    return null;
  }

  /// Fetch file path from Telegram and download bytes.
  Future<Uint8List?> _downloadFile(String fileId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/getFile',
        queryParameters: {'file_id': fileId},
      );
      final filePath = res.data?['result']?['file_path'] as String?;
      if (filePath == null) return null;

      final dlDio = Dio();
      final dlRes = await dlDio.get<List<int>>(
        '$_fileBase$token/$filePath',
        options: Options(responseType: ResponseType.bytes),
      );
      if (dlRes.data == null) return null;
      return Uint8List.fromList(dlRes.data!);
    } catch (e) {
      _log.warning('Failed to download Telegram file $fileId: $e');
      return null;
    }
  }

  String _mimeToExt(String mime) {
    if (mime.contains('ogg')) return 'ogg';
    if (mime.contains('mpeg') || mime.contains('mp3')) return 'mp3';
    if (mime.contains('mp4') || mime.contains('m4a')) return 'm4a';
    if (mime.contains('wav')) return 'wav';
    return 'ogg';
  }

  String _extractSenderName(Map<String, dynamic> from) {
    final first = from['first_name'] as String? ?? '';
    final last = from['last_name'] as String? ?? '';
    final un = from['username'] as String?;
    if (first.isEmpty && last.isEmpty) return un ?? 'User';
    return '$first $last'.trim();
  }

  String _extractText(Map<String, dynamic> message) {
    final text = message['text'] as String?;
    if (text != null && text.isNotEmpty) return text;
    final caption = message['caption'] as String?;
    if (caption != null && caption.isNotEmpty) return caption;
    return '';
  }

  Future<List<Map<String, dynamic>>> _getUpdates() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/getUpdates',
      queryParameters: {
        'offset': _lastUpdateId + 1,
        'timeout': 30,
        'allowed_updates': ['message'],
      },
    );
    final data = res.data;
    if (data == null) return [];
    final list = data['result'] as List<dynamic>?;
    return list?.cast<Map<String, dynamic>>() ?? [];
  }

  @override
  Future<void> sendMessage(OutgoingMessage message) async {
    if (message.channelType != _type) return;

    // Send voice note if audio is attached
    if (message.audioBytes != null) {
      await _sendVoice(message.chatId, message.audioBytes!,
          replyToMessageId: message.replyToMessageId);
    }

    // Always also send text
    if (message.text.isNotEmpty) {
      final chunks = _splitMessage(message.text, 4000);
      for (final chunk in chunks) {
        final params = <String, dynamic>{
          'chat_id': message.chatId,
          'text': chunk,
          'parse_mode': 'Markdown',
        };
        if (message.replyToMessageId != null) {
          params['reply_to_message_id'] =
              int.tryParse(message.replyToMessageId!) ??
                  message.replyToMessageId;
        }
        try {
          await _dio.post('/sendMessage', data: params);
        } catch (e, _) {
          // Markdown rejected — retry as plain text.
          _log.warning('Telegram Markdown send failed, retrying as plain text',
              e);
          try {
            params.remove('parse_mode');
            await _dio.post('/sendMessage', data: params);
          } catch (e2, st2) {
            _log.severe('Telegram plain text send also failed', e2, st2);
            rethrow;
          }
        }
      }
    }
  }

  /// Send audio bytes as a Telegram voice note (OGG/Opus expected, but WAV
  /// is also accepted by Telegram — it re-encodes server-side).
  Future<void> _sendVoice(
    String chatId,
    Uint8List audioBytes, {
    String? replyToMessageId,
  }) async {
    try {
      final formData = FormData.fromMap({
        'chat_id': chatId,
        'voice': MultipartFile.fromBytes(audioBytes, filename: 'voice.ogg'),
        if (replyToMessageId != null)
          'reply_to_message_id':
              int.tryParse(replyToMessageId) ?? replyToMessageId,
      });
      await _dio.post('/sendVoice', data: formData);
    } catch (e, st) {
      _log.warning('Failed to send Telegram voice message', e, st);
    }
  }

  List<String> _splitMessage(String text, int maxLen) {
    if (text.length <= maxLen) return [text];
    final chunks = <String>[];
    var remaining = text;
    while (remaining.length > maxLen) {
      var splitAt = remaining.lastIndexOf('\n', maxLen);
      if (splitAt <= 0) splitAt = maxLen;
      chunks.add(remaining.substring(0, splitAt));
      remaining = remaining.substring(splitAt).trimLeft();
    }
    if (remaining.isNotEmpty) chunks.add(remaining);
    return chunks;
  }
}
