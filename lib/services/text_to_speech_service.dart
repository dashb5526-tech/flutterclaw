/// Text-to-speech service using the system TTS engine (flutter_tts).
///
/// Wraps [FlutterTts] to provide a simple API for synthesizing text to an
/// audio file or for direct speech playback. Uses the platform's built-in
/// voices — no API key required.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('TextToSpeechService');

class TextToSpeechService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isSpeaking = false;
  bool _synthesizing = false;

  bool get isSpeaking => _isSpeaking;

  /// Initialize TTS engine with sensible defaults.
  Future<void> init() async {
    if (_initialized) return;
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      if (Platform.isIOS) {
        await _tts.setSharedInstance(true);
        // Use 'playback' category so speech plays even when the device is in
        // silent/vibrate mode — same behaviour as navigation and Siri.
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          ],
        );
      }
      // Try to select the best available neural voice for the device locale.
      await _selectBestVoice();
      _initialized = true;
      _log.info('TTS initialized');
    } catch (e) {
      _log.warning('TTS init failed: $e');
    }
  }

  /// Select the highest-quality available voice for the device locale.
  ///
  /// On iOS, Apple ships compact (robotic), Enhanced, and Premium (neural)
  /// voices. Premium > Enhanced > default. The voice must be downloaded by
  /// the user in Settings → Accessibility → Spoken Content → Voices; this
  /// method picks the best one that is already available on the device.
  Future<void> _selectBestVoice() async {
    try {
      final rawVoices = await _tts.getVoices;
      if (rawVoices == null) return;
      final voices = (rawVoices as List).cast<Map>();
      if (voices.isEmpty) return;

      // Match device locale language (e.g. 'es' from 'es_ES').
      final deviceLang = Platform.localeName.split('_').first.toLowerCase();

      // Prefer voices whose locale starts with the device language; fall
      // back to the full list so we always pick something.
      final candidates = voices
          .where(
            (v) => (v['locale'] as String? ?? '')
                .toLowerCase()
                .startsWith(deviceLang),
          )
          .toList();
      final pool = candidates.isNotEmpty ? candidates : voices;

      // Pick the highest quality: Premium > Enhanced > first available.
      Map? best;
      for (final quality in ['Premium', 'Enhanced']) {
        best = pool.cast<Map?>().firstWhere(
          (v) => (v?['name'] as String? ?? '').contains(quality),
          orElse: () => null,
        );
        if (best != null) break;
      }
      best ??= pool.isNotEmpty ? pool.first : null;

      if (best != null) {
        final name = best['name'] as String?;
        final locale = best['locale'] as String?;
        if (name != null && locale != null) {
          await _tts.setVoice({'name': name, 'locale': locale});
          await _tts.setLanguage(locale);
          _log.info('TTS voice selected: $name ($locale)');
        }
      }
    } catch (e) {
      _log.warning('TTS voice selection failed: $e');
    }
  }

  /// Speak [text] aloud using the system TTS engine (direct playback).
  ///
  /// [onDone] is called when speech finishes naturally, is cancelled, or
  /// encounters an error. No-op if a file synthesis is in progress.
  Future<void> speak(String text, {void Function()? onDone}) async {
    if (_synthesizing) {
      _log.warning('TTS: speak() skipped — synthesizeToFile in progress');
      return;
    }
    await init();
    try {
      _tts.setStartHandler(() => _isSpeaking = true);
      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        onDone?.call();
      });
      _tts.setCancelHandler(() {
        _isSpeaking = false;
        onDone?.call();
      });
      _tts.setErrorHandler((_) {
        _isSpeaking = false;
        onDone?.call();
      });
      await _tts.speak(text);
    } catch (e) {
      _isSpeaking = false;
      onDone?.call();
      _log.warning('TTS speak failed: $e');
    }
  }

  /// Stop any in-progress speech.
  Future<void> stop() async {
    try {
      await _tts.stop();
      _isSpeaking = false;
    } catch (e) {
      _log.warning('TTS stop failed: $e');
    }
  }

  /// Synthesize [text] and write the result to a temp WAV file.
  ///
  /// Returns the file path on success, or null if synthesis failed.
  /// The caller is responsible for deleting the file after use.
  Future<String?> synthesizeToFile(String text) async {
    await init();
    _synthesizing = true;
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.wav';

      final completer = Completer<void>();
      _tts.setCompletionHandler(() {
        if (!completer.isCompleted) completer.complete();
      });
      _tts.setErrorHandler((msg) {
        if (!completer.isCompleted) completer.completeError(msg.toString());
      });

      final result = await _tts.synthesizeToFile(text, path);
      if (result != 1) {
        _log.warning('TTS synthesizeToFile returned $result');
        return null;
      }

      // Wait for completion (timeout after 30s)
      await completer.future.timeout(const Duration(seconds: 30));

      final file = File(path);
      if (!await file.exists()) {
        _log.warning('TTS output file not found: $path');
        return null;
      }

      _log.info('TTS synthesized ${text.length} chars → $path');
      return path;
    } catch (e) {
      _log.warning('TTS synthesis failed: $e');
      return null;
    } finally {
      _synthesizing = false;
    }
  }

  /// Set the TTS language (BCP-47, e.g. 'es-ES', 'en-US').
  Future<void> setLanguage(String lang) async {
    await init();
    try {
      await _tts.setLanguage(lang);
    } catch (e) {
      _log.warning('TTS setLanguage failed: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
