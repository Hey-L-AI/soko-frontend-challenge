import 'package:flutter/widgets.dart';

/// PROD-3124 — slot allocator for the right-edge debug tabs.
///
/// The app-wide **Feedback tab owns a FIXED anchor** at
/// [kRightEdgeTabAnchorFraction] of screen height and NEVER moves (by
/// decision). Every other right-edge tab (Loc, Map Debug, …) claims the first
/// free slot BELOW it at mount and releases it on unmount — so any
/// combination of tabs mounted from *different* Stacks (the discovery shell
/// mounts Loc, the Map page mounts Debug) stacks cleanly instead of
/// overlapping (previously both hard-coded the same `0.4h + 140` spot).
///
/// Deliberately a plain static registry, NOT a provider:
/// * claiming happens in `initState`/first-build, where Riverpod forbids
///   provider writes;
/// * nothing needs to *react* to a claim — a tab reads its own slot once, and
///   re-shuffling live (when a neighbour unmounts) would move tabs under the
///   user's finger. A released slot is simply reused by the next mount.
class RightEdgeTabSlots {
  RightEdgeTabSlots._();

  static final Set<int> _claimed = <int>{};

  /// Claim the lowest free slot index. Pair with [release].
  static int claim() {
    var i = 0;
    while (_claimed.contains(i)) {
      i++;
    }
    _claimed.add(i);
    return i;
  }

  /// Release a slot claimed with [claim]. Safe on null / double release.
  static void release(int? slot) {
    if (slot != null) _claimed.remove(slot);
  }

  /// Test hook — clear all claims.
  @visibleForTesting
  static void reset() => _claimed.clear();
}

/// The Feedback tab's fixed top, as a fraction of screen height. Mirrors
/// `FeedbackSideTab` (`top: height * 0.4`) — keep the two in sync.
const double kRightEdgeTabAnchorFraction = 0.4;

/// Clearance below the Feedback tab to the first claimable slot (covers the
/// Feedback tab's own footprint).
const double kRightEdgeTabFirstOffset = 140;

/// Vertical pitch between claimed slots (tallest tab ≈ 90 px + breathing room).
const double kRightEdgeTabPitch = 108;

/// The `top` for a claimed [slot] index.
double rightEdgeTabSlotTop(BuildContext context, int slot) =>
    MediaQuery.sizeOf(context).height * kRightEdgeTabAnchorFraction +
    kRightEdgeTabFirstOffset +
    slot * kRightEdgeTabPitch;
