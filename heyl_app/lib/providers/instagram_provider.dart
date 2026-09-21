import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/services/storage_service.dart';
import '../core/utils/web_navigation.dart';
import '../data/datasources/interfaces/api_interfaces.dart';
import '../data/models/instagram_connection.dart';
import 'api_provider.dart';
import 'auth_provider.dart';

/// Status of the Instagram integration
enum InstagramStatus {
  loading,
  noConnection,
  connecting,
  connected,
  disconnecting,
  error,
}

/// State for Instagram integration
class InstagramState {
  final InstagramStatus status;
  final List<InstagramConnection> connections;
  final String? errorReason;

  const InstagramState({
    this.status = InstagramStatus.loading,
    this.connections = const [],
    this.errorReason,
  });

  InstagramState copyWith({
    InstagramStatus? status,
    List<InstagramConnection>? connections,
    String? errorReason,
  }) {
    return InstagramState(
      status: status ?? this.status,
      connections: connections ?? this.connections,
      errorReason: errorReason,
    );
  }
}

/// Notifier for managing Instagram connections
class InstagramNotifier extends StateNotifier<InstagramState> {
  final IInstagramApi _api;
  final Future<void> Function() _ensureFreshToken;
  final StorageService _storage;

  InstagramNotifier(this._api, this._ensureFreshToken, this._storage)
    : super(const InstagramState());

  /// Load existing Instagram connections
  Future<void> loadConnections() async {
    state = state.copyWith(status: InstagramStatus.loading, errorReason: null);
    try {
      final response = await _api.listConnections();
      state = InstagramState(
        status: response.connections.isEmpty
            ? InstagramStatus.noConnection
            : InstagramStatus.connected,
        connections: response.connections,
      );
    } catch (e) {
      debugPrint('[InstagramNotifier] loadConnections error: $e');
      state = state.copyWith(
        status: InstagramStatus.error,
        errorReason: 'load_failed',
      );
    }
  }

  /// Start the Instagram OAuth connect flow.
  ///
  /// [returnPath] is where to send the user after the callback. Pass it from
  /// the Business Connect portal (`/business`, `/menu/business-connections`) so
  /// the owner is routed back there — and re-armed as a business session —
  /// instead of being dropped on `/home` and swept into consumer onboarding by
  /// the full-page OAuth reload wiping in-memory state (PROD-4040). Persisted
  /// to SharedPreferences right before the redirect so it survives that reload.
  Future<void> startConnect({String? returnPath}) async {
    state = state.copyWith(
      status: InstagramStatus.connecting,
      errorReason: null,
    );
    try {
      // Proactively refresh the token before navigating away.
      // On web, launchUrl(_self) causes a full page reload on return;
      // a fresh token maximizes the chance the session survives.
      await _ensureFreshToken();

      final response = await _api.getConnectUrl();
      final url = Uri.parse(response.authorizationUrl);
      // Persist only now that a redirect is imminent (getConnectUrl succeeded),
      // so a failed start never leaves a stale return path behind.
      if (returnPath != null) {
        await _storage.saveBusinessConnectReturnPath(returnPath);
      }
      if (kIsWeb) {
        // On web, window.open() triggers iOS Universal Link handling which
        // opens the Instagram app instead of staying in the browser.
        // A hidden form submission bypasses Universal Links entirely.
        navigateViaForm(url.toString());
      } else {
        // iOS: externalApplication opens Safari; Universal Links return to app.
        // Android: inAppBrowserView opens a Chrome Custom Tab which prevents
        // the Instagram app from intercepting the OAuth URL via App Links.
        await launchUrl(
          url,
          mode: defaultTargetPlatform == TargetPlatform.android
              ? LaunchMode.inAppBrowserView
              : LaunchMode.externalApplication,
        );
      }
    } catch (e) {
      debugPrint('[InstagramNotifier] startConnect error: $e');
      // Check if the error is a 500 "not configured" response
      final errorStr = e.toString();
      final isNotConfigured =
          errorStr.contains('500') || errorStr.contains('not configured');
      state = state.copyWith(
        status: InstagramStatus.error,
        errorReason: isNotConfigured ? 'not_configured' : 'connect_failed',
      );
    }
  }

  /// Handle the OAuth callback result
  Future<void> handleCallbackResult(bool success, String? reason) async {
    if (success) {
      await loadConnections();
    } else {
      state = state.copyWith(
        status: InstagramStatus.error,
        errorReason: reason ?? 'unknown',
      );
    }
  }

  /// Fetch pending connection details for a duplicate warning
  Future<PendingConnectionResponse> fetchPendingConnection(String key) async {
    return _api.getPendingConnection(key);
  }

  /// Confirm a pending connection despite duplicate
  Future<bool> confirmPendingConnection(String key) async {
    try {
      await _api.confirmPendingConnection(key);
      await loadConnections();
      return true;
    } catch (e) {
      debugPrint('[InstagramNotifier] confirmPendingConnection error: $e');
      return false;
    }
  }

  /// Disconnect an Instagram account
  Future<bool> disconnect(String connectionId) async {
    state = state.copyWith(status: InstagramStatus.disconnecting);
    try {
      await _api.disconnect(connectionId);
      final updated = state.connections
          .where((c) => c.id != connectionId)
          .toList();
      state = InstagramState(
        status: updated.isEmpty
            ? InstagramStatus.noConnection
            : InstagramStatus.connected,
        connections: updated,
      );
      return true;
    } catch (e) {
      debugPrint('[InstagramNotifier] disconnect error: $e');
      state = state.copyWith(
        status: InstagramStatus.connected,
        errorReason: 'disconnect_failed',
      );
      return false;
    }
  }
}

/// Provider for Instagram state management
final instagramProvider =
    StateNotifierProvider<InstagramNotifier, InstagramState>((ref) {
      final api = ref.watch(instagramApiProvider);
      final authNotifier = ref.read(authStateProvider.notifier);
      final storage = ref.read(storageServiceProvider);
      return InstagramNotifier(
        api,
        () => authNotifier.ensureFreshToken(),
        storage,
      );
    });
