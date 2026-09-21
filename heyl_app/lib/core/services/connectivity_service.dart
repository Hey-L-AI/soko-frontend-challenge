import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Connectivity status enum
enum ConnectivityStatus { online, offline }

/// Service for monitoring network connectivity
class ConnectivityService {
  final Connectivity _connectivity;
  final StreamController<ConnectivityStatus> _statusController =
      StreamController<ConnectivityStatus>.broadcast();

  ConnectivityStatus _currentStatus = ConnectivityStatus.online;

  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    _init();
  }

  /// Initialize connectivity monitoring
  Future<void> _init() async {
    // Check initial status
    final result = await _connectivity.checkConnectivity();
    _updateStatus(result);

    // Listen for changes
    _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  /// Update status based on connectivity result
  void _updateStatus(ConnectivityResult result) {
    final hasConnection = result != ConnectivityResult.none;
    final newStatus = hasConnection
        ? ConnectivityStatus.online
        : ConnectivityStatus.offline;

    if (newStatus != _currentStatus) {
      _currentStatus = newStatus;
      _statusController.add(_currentStatus);
    }
  }

  /// Re-poll the live connectivity state and update status accordingly.
  ///
  /// Needed because the platform `onConnectivityChanged` event channel does
  /// not deliver events while the app is paused (Android buffers/drops them,
  /// iOS suspends the engine). A "back online" event that fires during
  /// background is lost, leaving the offline banner stuck until restart.
  /// Call this on `AppLifecycleState.resumed` to recover the missed event.
  Future<void> refresh() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateStatus(result);
    } catch (e) {
      // Best-effort re-poll: called fire-and-forget on resume, so a thrown
      // checkConnectivity() must not surface as an unhandled async error.
      // Leave status unchanged; the next stream event / resume recovers.
      debugPrint('[ConnectivityService] refresh failed: $e');
    }
  }

  /// Current connectivity status
  ConnectivityStatus get currentStatus => _currentStatus;

  /// Stream of connectivity status changes
  Stream<ConnectivityStatus> get statusStream => _statusController.stream;

  /// Check if currently online
  bool get isOnline => _currentStatus == ConnectivityStatus.online;

  /// Dispose resources
  void dispose() {
    _statusController.close();
  }
}

/// Provider for ConnectivityService
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for current connectivity status
final connectivityStatusProvider = StreamProvider<ConnectivityStatus>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  return service.statusStream;
});

/// Provider for checking if currently online
final isOnlineProvider = Provider<bool>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  final statusAsync = ref.watch(connectivityStatusProvider);

  // Use stream value if available, otherwise use service's current status
  return statusAsync.maybeWhen(
    data: (status) => status == ConnectivityStatus.online,
    orElse: () => service.isOnline,
  );
});
