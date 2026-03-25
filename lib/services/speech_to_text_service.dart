/// Offline speech-to-text service wrapping the `speech_to_text` plugin.
///
/// Uses iOS SFSpeechRecognizer (on-device, no network) or Android
/// SpeechRecognizer (on-device preferred, may use system default).
/// No API key required.
library;

import 'package:logging/logging.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

final _log = Logger('SpeechToTextService');

class SpeechToTextService {
  final SpeechToText _stt = SpeechToText();
  bool _available = false;
  bool _initialized = false;

  bool get isAvailable => _available;
  bool get isListening => _stt.isListening;

  /// Initialize the plugin and request speech recognition permission.
  ///
  /// Returns true if the device supports STT and permission was granted.
  /// Must be called before [startListening]. Safe to call multiple times.
  Future<bool> initialize() async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _stt.initialize(
        onError: (SpeechRecognitionError error) {
          _log.warning(
            'STT error: ${error.errorMsg} (permanent: ${error.permanent})',
          );
        },
        onStatus: (String status) {
          _log.fine('STT status: $status');
        },
        debugLogging: false,
      );
      _log.info('STT initialized, available=$_available');
    } catch (e) {
      _log.warning('STT initialization failed: $e');
      _available = false;
    }
    return _available;
  }

  /// Start live streaming recognition.
  ///
  /// [onResult] is called repeatedly with partial text and once with
  /// [isFinal]=true when the user stops or silence is detected.
  ///
  /// [localeId] is optional (e.g. 'en-US'). Defaults to device locale.
  ///
  /// Returns false if STT is unavailable or permission is denied.
  Future<bool> startListening({
    required void Function(String text, bool isFinal) onResult,
    String? localeId,
  }) async {
    if (!_available) {
      _log.warning('STT not available');
      return false;
    }
    try {
      await _stt.listen(
        onResult: (SpeechRecognitionResult result) {
          onResult(result.recognizedWords, result.finalResult);
        },
        localeId: localeId,
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.confirmation,
        ),
      );
      return true;
    } catch (e) {
      _log.warning('STT startListening failed: $e');
      return false;
    }
  }

  /// Stop listening and let the engine produce a final result callback.
  Future<void> stopListening() async {
    try {
      await _stt.stop();
    } catch (e) {
      _log.warning('STT stopListening failed: $e');
    }
  }

  /// Cancel recognition without producing a final result.
  Future<void> cancel() async {
    try {
      await _stt.cancel();
    } catch (e) {
      _log.warning('STT cancel failed: $e');
    }
  }
}
