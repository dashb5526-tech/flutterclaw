import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutterclaw/app.dart';
import 'package:flutterclaw/firebase_options.dart';
import 'package:flutterclaw/services/audio_player_service.dart';
import 'package:flutterclaw/services/background_service.dart';
import 'package:flutterclaw/services/live_activity_service.dart';
import 'package:logging/logging.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('[${record.level.name}] ${record.loggerName}: ${record.message}');
  });

  // Live Activities initialization disabled - causes crashes on simulator
  // The LiveActivityService will handle initialization lazily when needed
  // This works fine on physical devices
  // ignore: avoid_print
  print('ℹ️ Live Activities: deferred initialization (physical devices only)');

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Initialize audio service on iOS only. On Android the gateway runs in a
  // foreground service so we don't need audio for keep-alive; media_play
  // / media_control will report "not initialized" on Android unless we add it here.
  if (Platform.isIOS) {
    try {
      await initAudioService();
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ audio_service init failed (background audio unavailable): $e');
    }
    // End any stale Live Activities left over from a previous session (force-close,
    // crash, etc.). The iOS gateway runs in-process, so if the app was killed the
    // gateway is definitely not running — it's always safe to clear here.
    await LiveActivityService.endAllActivities();
  }

  // Only initialize flutter_foreground_task on Android
  // iOS uses a different approach with background audio
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
    await BackgroundService.initializeService();
  }

  runApp(const FlutterClawApp());
}
