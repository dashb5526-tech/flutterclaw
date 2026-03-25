import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutterclaw/core/app_providers.dart';
import 'package:flutterclaw/l10n/l10n_extension.dart';

/// Microphone button in the chat input bar.
///
/// Tap to start offline speech recognition; partial results are shown live
/// in the button's tooltip. Tap again (or wait for silence) to stop — the
/// final recognised text is sent as a chat message.
///
/// Uses the OS speech recogniser (iOS SFSpeechRecognizer / Android
/// SpeechRecognizer) — no API key or network call required.
class VoiceMicButton extends ConsumerStatefulWidget {
  const VoiceMicButton({super.key});

  @override
  ConsumerState<VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends ConsumerState<VoiceMicButton> {
  bool _listening = false;
  bool _initializing = false;
  String _liveText = '';

  Future<void> _toggle() async {
    final stt = ref.read(speechToTextServiceProvider);

    if (_listening) {
      // Stop: request final result from the engine.
      // The onResult(isFinal=true) callback will send the message.
      await stt.stopListening();
      HapticFeedback.lightImpact();
      if (mounted) setState(() { _listening = false; _liveText = ''; });
      return;
    }

    // Start: initialise (requests permission on first call).
    if (mounted) setState(() => _initializing = true);
    final available = await stt.initialize();

    if (!available) {
      if (mounted) {
        setState(() => _initializing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.liveTranscriptionUnavailable(
                'Speech recognition not available on this device',
              ),
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final started = await stt.startListening(
      onResult: (String text, bool isFinal) {
        if (!mounted) return;
        setState(() => _liveText = text);
        if (isFinal) {
          setState(() { _listening = false; _liveText = ''; });
          if (text.trim().isNotEmpty) {
            ref.read(chatProvider.notifier).sendMessage(text.trim());
          }
        }
      },
    );

    if (!started && mounted) {
      setState(() { _initializing = false; _listening = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.microphonePermissionDenied),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (mounted) {
      HapticFeedback.mediumImpact();
      setState(() { _initializing = false; _listening = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_initializing) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return IconButton.filled(
      onPressed: _toggle,
      style: _listening
          ? IconButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            )
          : null,
      icon: Icon(_listening ? Icons.stop_rounded : Icons.mic),
      tooltip: _listening
          ? (_liveText.isNotEmpty ? _liveText : context.l10n.stopRecording)
          : context.l10n.voiceInput,
    );
  }
}
