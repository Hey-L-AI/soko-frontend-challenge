import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_state.dart';

/// Holds the single currently-visible notification (or null). Auto-replace
/// semantics: a `show` while another is visible replaces it. The host
/// widget watches this provider and animates the visual in/out.
class NotificationsNotifier extends Notifier<SokoState?> {
  Timer? _autoDismiss;
  int _tokens = 0;

  @override
  SokoState? build() {
    ref.onDispose(() => _autoDismiss?.cancel());
    return null;
  }

  /// Show (or replace) the visible notification. Pass an
  /// already-tokened state from `showSoko`.
  void _set(SokoState next) {
    _autoDismiss?.cancel();
    state = next;
    if (!next.sticky && next.duration != null) {
      _autoDismiss = Timer(next.duration!, () {
        if (state?.token == next.token) dismiss();
      });
    }
  }

  /// Construct a state with a freshly minted token and show it.
  void show({
    required String message,
    required SokoVariant variant,
    SokoAction? action,
    Duration? duration,
    bool sticky = false,
    IconData? icon,
    VoidCallback? onDismissed,
  }) {
    _tokens++;
    _set(SokoState(
      message: message,
      variant: variant,
      action: action,
      duration: duration,
      sticky: sticky,
      icon: icon,
      onDismissed: onDismissed,
      token: _tokens,
    ));
  }

  /// Clear the current notification (if any) and fire its onDismissed.
  void dismiss() {
    final cur = state;
    _autoDismiss?.cancel();
    _autoDismiss = null;
    if (cur == null) return;
    state = null;
    cur.onDismissed?.call();
  }
}

final notificationsProvider =
    NotifierProvider<NotificationsNotifier, SokoState?>(
  NotificationsNotifier.new,
);

/// Vertical space (in logical pixels) currently reserved at the bottom of
/// the viewport by chrome that the toast must NOT cover — today that's
/// the [DiscoveryBottomNav], including its iOS home-indicator safe-area
/// padding. Set by [DiscoveryShell] when the nav mounts/animates, read by
/// [NotificationHost] so the bottom-anchored notification slides in
/// immediately above the nav instead of overlapping it.
///
/// `0.0` means "no shell chrome below" — the host then falls back to the
/// viewport's own bottom safe-area inset. PROD-1885 polish (the toast
/// was previously top-anchored, which left no overlap risk; moving it
/// to the bottom required this provider to keep the nav visible).
final notificationBottomInsetProvider = StateProvider<double>((ref) => 0.0);
