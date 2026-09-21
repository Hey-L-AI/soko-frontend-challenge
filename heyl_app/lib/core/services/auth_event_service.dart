import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Authentication events that can be broadcast app-wide
enum AuthEvent {
  /// Session expired - token refresh failed, user needs to re-login
  sessionExpired,

  /// PROD-2264 — Backend returned a 403 [ModerationErrorResponse] with
  /// `error_code: USER_SUSPENDED | USER_BANNED`. The handler force-
  /// logs out and routes to the suspended-account landing screen.
  accountSuspended,
}

/// Service for broadcasting authentication-related events.
/// This allows the API layer to communicate auth state changes
/// without directly depending on Riverpod or UI layer.
class AuthEventService {
  final StreamController<AuthEvent> _eventController =
      StreamController<AuthEvent>.broadcast();

  /// Stream of authentication events
  Stream<AuthEvent> get eventStream => _eventController.stream;

  /// Broadcast that the session has expired
  void notifySessionExpired() {
    _eventController.add(AuthEvent.sessionExpired);
  }

  /// PROD-2264 — Broadcast that the current account has been
  /// suspended or banned by backoffice T&S.
  void notifyAccountSuspended() {
    _eventController.add(AuthEvent.accountSuspended);
  }

  /// Dispose resources
  void dispose() {
    _eventController.close();
  }
}

/// Provider for AuthEventService (singleton)
final authEventServiceProvider = Provider<AuthEventService>((ref) {
  final service = AuthEventService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Stream provider for auth events
final authEventStreamProvider = StreamProvider<AuthEvent>((ref) {
  final service = ref.watch(authEventServiceProvider);
  return service.eventStream;
});
