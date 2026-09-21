import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart' show isItemSavedProvider;
import '../../feature_spotlight/spotlight_route_observer.dart';

/// Wraps the reminder bell with a non-blocking comic-bubble nudge
/// (PROD-2929). When the user saves the event, a squarish speech bubble
/// pops up under the bell — "Saved! Want a nudge before it starts?" —
/// pointing up at it. Tapping the bubble opens the reminder picker; it
/// also auto-dismisses after a few seconds.
///
/// Deliberately lightweight vs the `SpotlightTrigger` coach-mark: no
/// scrim, no barrier, no once-ever server state. It's a soft, repeatable
/// hint, not an onboarding gate.
///
/// Show rules ("sometimes"):
///   - [enabled] (admin flag) must be true.
///   - Fires on the save → true transition of `isItemSavedProvider`.
///   - Skipped when [alreadyReminded] (nudging an existing reminder is
///     pointless).
///   - At most once per app session (a static guard; resets on hot
///     restart so it stays demoable).
///   - Deferred until the add-to-list sheet closes (modal count drains
///     to 0) so the bubble doesn't render behind the sheet.
class SaveReminderHint extends ConsumerStatefulWidget {
  const SaveReminderHint({
    super.key,
    required this.eventId,
    required this.enabled,
    required this.alreadyReminded,
    required this.onTap,
    required this.child,
  });

  final String eventId;
  final bool enabled;

  /// True when the event already has a reminder / `going` set — suppresses
  /// the hint.
  final bool alreadyReminded;

  /// Invoked when the user taps the bubble (opens the reminder picker).
  final VoidCallback onTap;

  final Widget child;

  /// At most one nudge per app session, across all events. Static so it
  /// survives page navigation but resets on a hot restart / cold start.
  static bool _shownThisSession = false;

  @override
  ConsumerState<SaveReminderHint> createState() => _SaveReminderHintState();
}

class _SaveReminderHintState extends ConsumerState<SaveReminderHint> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _bubble;
  Timer? _autoDismiss;

  /// Previous saved-state observation. Null until the first build so we
  /// never fire on mount of an already-saved event — only on a genuine
  /// false → true transition.
  bool? _wasSaved;

  /// Set while we're waiting for the add-to-list sheet to close before
  /// showing the bubble.
  bool _pendingShow = false;

  @override
  void dispose() {
    spotlightModalObserver.activeModalCount.removeListener(_onModalDrain);
    _autoDismiss?.cancel();
    _removeBubble();
    super.dispose();
  }

  void _removeBubble() {
    _bubble?.remove();
    _bubble = null;
  }

  void _onSaveTransition() {
    if (!widget.enabled) return;
    if (widget.alreadyReminded) return;
    if (SaveReminderHint._shownThisSession) return;
    if (_pendingShow || _bubble != null) return;

    // The save happens inside the add-to-list sheet. Wait for the modal
    // stack to drain before popping the bubble so it doesn't render
    // underneath the sheet.
    if (spotlightModalObserver.activeModalCount.value == 0) {
      _show();
    } else {
      _pendingShow = true;
      spotlightModalObserver.activeModalCount.addListener(_onModalDrain);
    }
  }

  void _onModalDrain() {
    if (spotlightModalObserver.activeModalCount.value != 0) return;
    spotlightModalObserver.activeModalCount.removeListener(_onModalDrain);
    if (!_pendingShow) return;
    _pendingShow = false;
    if (!mounted) return;
    // Re-check the suppressors — the user may have set a reminder inside
    // the sheet, or the bubble may already be up.
    if (widget.alreadyReminded || SaveReminderHint._shownThisSession) return;
    _show();
  }

  void _show() {
    SaveReminderHint._shownThisSession = true;
    _bubble = OverlayEntry(
      builder: (_) => _ReminderHintBubble(
        link: _link,
        message: Lt.of(context).eventReminderSaveHint,
        onTap: () {
          _removeBubble();
          _autoDismiss?.cancel();
          widget.onTap();
        },
      ),
    );
    Overlay.of(context).insert(_bubble!);
    _autoDismiss = Timer(const Duration(seconds: 6), _removeBubble);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.enabled) {
      final isSaved = ref.watch(isItemSavedProvider)(eventId: widget.eventId);
      if (_wasSaved != null && !_wasSaved! && isSaved) {
        // Defer to post-frame — we can't insert an overlay mid-build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onSaveTransition();
        });
      }
      _wasSaved = isSaved;
    }
    return CompositedTransformTarget(link: _link, child: widget.child);
  }
}

/// The comic speech bubble: paper fill, thick ink outline, hard offset
/// shadow, an up-pointer joined to the box, anchored under the bell.
class _ReminderHintBubble extends StatelessWidget {
  const _ReminderHintBubble({
    required this.link,
    required this.message,
    required this.onTap,
  });

  final LayerLink link;
  final String message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Non-blocking: only the follower is in the overlay — no full-screen
    // barrier — so taps elsewhere pass straight through to the page.
    return CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomCenter,
      followerAnchor: Alignment.topCenter,
      offset: const Offset(0, 8),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Up-pointer (comic tail) joined to the box below.
              CustomPaint(size: const Size(16, 8), painter: _PointerPainter()),
              Transform.translate(
                offset: const Offset(0, -1),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 220),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.sokoPaper,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.sokoInk, width: 2),
                    boxShadow: const [
                      // Hard offset (no blur) for the comic-panel look.
                      BoxShadow(color: AppColors.sokoInk, offset: Offset(3, 3)),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        LucideIcons.bell_ring,
                        size: 16,
                        color: AppColors.sokoInk,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          message,
                          style: const TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                            color: AppColors.sokoInk,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the upward triangular tail with the same paper fill + ink
/// outline as the box, so the two read as one comic bubble.
class _PointerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(0, size.height)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = AppColors.sokoPaper);
    // Only stroke the two slanted edges — the base sits under the box
    // border so it shouldn't draw a line across the joint.
    final border = Paint()
      ..color = AppColors.sokoInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height),
      border,
    );
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) => false;
}
