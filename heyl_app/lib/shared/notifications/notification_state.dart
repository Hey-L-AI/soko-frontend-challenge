import 'package:flutter/widgets.dart';

/// Visual variant of an in-app notification — drives the default icon and
/// icon tint. The card background and action label colors are constant
/// across variants (Soko/Paper + Soko/Pink) so the surface stays coherent
/// with the design system.
enum SokoVariant { info, success, error, loading }

/// Action button on a notification. Renders as a pill on `sokoInk` with
/// a `sokoPaper` label so it reads unambiguously as a button (PROD-1885).
class SokoAction {
  final String label;
  final VoidCallback onTap;
  const SokoAction({required this.label, required this.onTap});
}

/// Immutable spec of the currently-visible notification. `null` in the
/// provider means "no notification".
@immutable
class SokoState {
  final String message;
  final SokoVariant variant;
  final SokoAction? action;

  /// When non-null and not [sticky], the notification auto-dismisses
  /// after this duration. Defaults applied at the call site
  /// (`showSoko`) so the model stays declarative.
  final Duration? duration;

  /// When true, the notification stays until the user taps X or
  /// `dismissSoko` is called. Overrides [duration].
  final bool sticky;

  /// Overrides the variant's default Lucide glyph. `null` keeps the
  /// variant default; ignored for `loading` (always renders a spinner).
  final IconData? icon;

  /// Fires when the notification is dismissed (auto-timeout, X tap, or
  /// programmatic dismiss). Used by callers that need to reset state on
  /// dismissal — currently only the lists-import sticky case.
  final VoidCallback? onDismissed;

  /// Monotonic token used by the host to identify "this is a new
  /// notification" vs. "the state happens to be equal". Two `show()`
  /// calls with identical args still get distinct tokens so the
  /// auto-dismiss timer re-arms.
  final int token;

  const SokoState({
    required this.message,
    required this.variant,
    required this.token,
    this.action,
    this.duration,
    this.sticky = false,
    this.icon,
    this.onDismissed,
  });
}
