import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dismisses a page-local overlay. Returns **true if it consumed the tap** —
/// false means "nothing to dismiss, carry on and do the normal thing".
typedef ShellStrayTapDismisser = bool Function();

/// PROD-3627 — set while a page-local overlay wants a stray tap on
/// **shell-level chrome** to dismiss it and do nothing else.
///
/// ## Why this exists
///
/// A page's own overlay can absorb taps anywhere inside that page by putting an
/// opaque scrim over it — which is how the map's focused search mode consumes
/// taps on the map, the drawer and the filter row. But `DiscoveryShell` floats
/// the side tabs (Feedback, and the admin location-debug tab) in a `Stack`
/// **above the whole Scaffold**, so they sit above any page's scrim and no
/// page-local layer can reach them. This is the seam for that gap, and only
/// that gap: the bottom nav has its own (`MapLeaveNavigationGuard`).
///
/// ## Why it returns bool
///
/// A registered global handler that a page forgets to clear is not a
/// hypothetical failure here — a leaked `MapLeaveNavigationGuard` once left
/// every bottom-nav tap dead until app restart. So this one is **leak-proof by
/// construction**: the callback re-checks whether it actually has anything to
/// dismiss and returns `false` if not. A stale registration therefore degrades
/// to a no-op, never to a permanently dead tab. Callers MUST honour the return
/// value rather than treating non-null as "consumed":
///
/// ```dart
/// final dismiss = ref.read(shellStrayTapDismissProvider);
/// if (dismiss != null && dismiss()) return; // consumed — do nothing else
/// ```
final shellStrayTapDismissProvider = StateProvider<ShellStrayTapDismisser?>(
  (ref) => null,
);
