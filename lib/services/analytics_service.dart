import 'package:flutter_riverpod/flutter_riverpod.dart';

class AnalyticsService {
  AnalyticsService();

  Future<void> logScreenView({
    required String screenName,
    String? screenClass,
  }) async {
    // Analytics disabled
  }

  Future<void> logTap({
    required String name,
    Map<String, Object>? parameters,
  }) async {
    // Analytics disabled
  }

  Future<void> logAction({
    required String name,
    Map<String, Object>? parameters,
  }) async {
    // Analytics disabled
  }
}

final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  return AnalyticsService();
});
