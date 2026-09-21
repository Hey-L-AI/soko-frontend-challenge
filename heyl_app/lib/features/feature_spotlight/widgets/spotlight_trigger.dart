import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:showcaseview/showcaseview.dart';

import '../../../data/models/feature_spotlight.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../providers/auth_provider.dart';
import '../../../l10n/generated/l10n.dart';
import '../providers/feature_spotlight_service.dart';
import '../spotlight_occlusion_probe.dart';
import '../spotlight_registry.dart';
import '../spotlight_route_observer.dart';
import 'spotlight_hand_overlay.dart';
import 'spotlight_tooltip.dart';

/// Wraps a target widget with a once-only feature spotlight (PROD-2808).
///
/// Fires `ShowCaseWidget.of(context).startShowCase([_key])` in a
/// post-frame callback when [FeatureSpotlightNotifier.shouldShow]
/// returns true. Dismiss / CTA tap marks the feature as seen (server +
/// local cache) so the spotlight never fires again for this user.
///
/// The parent screen must already be inside a `ShowCaseWidget` ancestor.
/// For the three first-batch spotlight surfaces (event detail, chat, list
/// page), that ancestor is `ProductTourHost` — already mounted around
/// `DiscoveryShell`.
///
/// Optional [gate] callback: return false to suppress the spotlight even
/// when the framework's own gates pass (e.g. "only show on event detail
/// if the user has no reminders on this event yet").
class SpotlightTrigger extends ConsumerStatefulWidget {
  const SpotlightTrigger({
    super.key,
    required this.featureId,
    required this.child,
    this.gate,
    this.onCtaAction,
    this.content,
    this.targetCornerRadius = 12.0,
    this.targetPadding = const EdgeInsets.all(6),
    this.tooltipPosition,
  });

  /// Identifier registered in [kFeatureSpotlights].
  final String featureId;

  /// The widget that should receive the spotlight cutout.
  final Widget child;

  /// Optional surface-specific gate. Returns false to suppress.
  final bool Function()? gate;

  /// Optional action to invoke when the user taps the spotlight's primary
  /// CTA. Called AFTER the showcase is dismissed and analytics recorded,
  /// so any sheet/dialog opened here renders cleanly on top. Pass `null`
  /// when the CTA is a pure acknowledgment (e.g. "Got it" on a spotlight
  /// teaching a gesture the user must perform themselves).
  final VoidCallback? onCtaAction;

  /// Corner radius of the showcase cutout around the target.
  final double targetCornerRadius;

  /// Padding between the target's bounding box and the cutout edge.
  final EdgeInsets targetPadding;

  /// Optional custom widget rendered inside the tooltip, between the body and
  /// the CTA (e.g. the mutual-follow Soko card on the profile spotlight).
  final Widget? content;

  /// Optional tooltip anchor. Defaults to package auto-placement.
  final TooltipPosition? tooltipPosition;

  @override
  ConsumerState<SpotlightTrigger> createState() => _SpotlightTriggerState();
}

class _SpotlightTriggerState extends ConsumerState<SpotlightTrigger> {
  /// Key attached to the `Showcase.withWidget` — showcaseview uses this
  /// to look up the target for `startShowCase`.
  final GlobalKey _key = GlobalKey();

  /// Key attached to the wrapped child via a `KeyedSubtree`. Lets us
  /// resolve the target's `RenderBox` (and thus its global rect) so the
  /// Soko hand overlay can be positioned adjacent to it.
  final GlobalKey _targetKey = GlobalKey();

  /// Key attached to the tooltip card's visible `Container`. Lets the Soko
  /// hand overlay resolve where `showcaseview` actually placed the card
  /// (which it may auto-flip past a screen edge) and sit on the opposite
  /// side of the target — see `spotlight_hand_overlay.dart`.
  final GlobalKey _tooltipCardKey = GlobalKey();

  OverlayEntry? _handOverlay;
  Timer? _fireDelayTimer;
  Timer? _occlusionRetryTimer;
  bool _started = false;
  bool _reservationHeld = false;
  bool _shownAnalyticsFired = false;

  /// Pre-fire delay after `_maybeStart` claims the slot. Gives the user a
  /// moment to orient on the screen before the coachmark fires, matching
  /// the onboarding cadence where content settles before the tour speaks.
  static const Duration _fireDelay = Duration(seconds: 3);

  /// Poll interval used to re-check occlusion while the target sits behind
  /// a persistent occluder (e.g. the Feedback side tab). Occlusion clears
  /// on scroll, which has no discrete event this trigger can listen for
  /// (it's a descendant of the scrollable), so we re-check on a short
  /// timer and fire the instant the target scrolls clear (PROD-2964).
  static const Duration _occlusionRetryInterval = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Re-arm the pre-fire timer whenever the modal stack drains back to
    // zero. If the user opened a sheet/dialog during the 3s wait,
    // `_maybeStart` / `_fireNow` bail without consuming the once-only
    // reservation; this listener retries when the sheet closes.
    spotlightModalObserver.activeModalCount.addListener(_onModalCountChanged);
    WidgetsBinding.instance.addPostFrameCallback(_maybeStart);
  }

  @override
  void didUpdateWidget(covariant SpotlightTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.featureId != widget.featureId) {
      // Release the old feature's reservation before we forget which id
      // we held.
      _releaseReservationIfHeld(oldWidget.featureId);
      _cancelFireDelay();
      _started = false;
      _shownAnalyticsFired = false;
      _removeHandOverlay();
      WidgetsBinding.instance.addPostFrameCallback(_maybeStart);
    }
  }

  @override
  void dispose() {
    // If the user navigated away without dismissing (or the trigger was
    // rebuilt out), free the active-spotlight slot so the next surface
    // isn't blocked.
    spotlightModalObserver.activeModalCount.removeListener(
      _onModalCountChanged,
    );
    _cancelFireDelay();
    _cancelOcclusionRetry();
    _releaseReservationIfHeld(widget.featureId);
    _removeHandOverlay();
    super.dispose();
  }

  void _onModalCountChanged() {
    if (!mounted) return;
    // Only re-arm on the falling edge (modals fully drained).
    if (spotlightModalObserver.activeModalCount.value != 0) return;
    if (_started) return;
    if (_fireDelayTimer != null) return;
    _maybeStart(Duration.zero);
  }

  void _releaseReservationIfHeld(String featureId) {
    if (!_reservationHeld) return;
    _reservationHeld = false;
    ref.read(featureSpotlightServiceProvider.notifier).release(featureId);
  }

  void _cancelFireDelay() {
    _fireDelayTimer?.cancel();
    _fireDelayTimer = null;
  }

  void _cancelOcclusionRetry() {
    _occlusionRetryTimer?.cancel();
    _occlusionRetryTimer = null;
  }

  /// Start (once) the poll that re-checks occlusion while the target sits
  /// behind a persistent occluder. Each tick retries `_maybeStart`; the
  /// timer clears itself once the spotlight fires or the trigger unmounts.
  void _ensureOcclusionRetry() {
    _occlusionRetryTimer ??= Timer.periodic(_occlusionRetryInterval, (_) {
      if (!mounted || _started) {
        _cancelOcclusionRetry();
        return;
      }
      _maybeStart(Duration.zero);
    });
  }

  /// True when the wrapped target is overshadowed by anything on screen —
  /// covered by chrome, scrolled out of view, or clipped. Uses a generic
  /// hit-test probe, so no occluder has to register (PROD-2964). An
  /// unresolvable target returns false (fail-open): showcaseview couldn't
  /// place a cutout on it anyway, so let the normal flow decide rather
  /// than poll forever.
  bool _isTargetOccluded() {
    final ctx = _targetKey.currentContext;
    if (ctx == null) return false;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return false;
    return SpotlightOcclusionProbe.isOccluded(ro, View.of(ctx).viewId);
  }

  void _maybeStart(Duration _) {
    if (!mounted || _started || _fireDelayTimer != null) return;
    // PROD-3115 — feature spotlights are once-only, server-tracked *per
    // user* coachmarks (`/users/me/feature-spotlights` 401s for guest
    // JWTs), so they are inherently signed-in-only. Never fire one for a
    // guest, on any surface. Bail BEFORE reserving the active-spotlight
    // slot so a guest can't hold it hostage.
    if (!ref.read(isAuthenticatedProvider)) {
      _cancelOcclusionRetry();
      return;
    }
    if (widget.gate != null && !widget.gate!()) {
      _cancelOcclusionRetry();
      return;
    }

    // Suppress the pre-fire timer while a modal (bottom sheet, dialog)
    // is on top of the app's navigation stack. Avoids consuming the
    // once-only reservation for a spotlight the user can't see, and
    // prevents firing on top of the modal 3s later. Re-armed by
    // `_onModalCountChanged` when the modal stack drains.
    if (spotlightModalObserver.activeModalCount.value > 0) return;

    final service = ref.read(featureSpotlightServiceProvider.notifier);
    if (!service.shouldShow(widget.featureId)) {
      _cancelOcclusionRetry();
      return;
    }

    // Defer while the target is hidden behind a persistent occluder (the
    // always-on Feedback side tab, PROD-2911). Bail BEFORE reserving so
    // the single active-spotlight slot stays free while we wait. Unlike
    // the modal gate there's no navigator falling-edge to re-arm on, so
    // keep a short poll running; it retries `_maybeStart` and fires the
    // instant the user scrolls the target clear (PROD-2964).
    if (_isTargetOccluded()) {
      _ensureOcclusionRetry();
      return;
    }
    _cancelOcclusionRetry();

    // Atomic check-and-set: only one spotlight can hold the active
    // slot at a time. When multiple SpotlightTriggers mount on the
    // same screen (e.g. event detail's bell + IG-share), whichever
    // post-frame callback fires first wins the slot; the rest bail
    // silently. The reservation is held THROUGH the pre-fire delay so
    // a sibling trigger can't sneak in during those 3 seconds.
    if (!service.tryReserve(widget.featureId)) return;
    _reservationHeld = true;

    // Delay the actual mount so the user has a moment to orient on the
    // screen before the coachmark appears. Cancellable — a
    // pre-fire dispose or featureId change kills the timer and releases
    // the reservation.
    _fireDelayTimer = Timer(_fireDelay, _fireNow);
  }

  void _fireNow() {
    _fireDelayTimer = null;
    if (!mounted || _started) return;
    // Re-check the gate at fire time: the user might have taken the
    // taught action during the delay (e.g. tapped the bell before the
    // spotlight rendered) making the spotlight redundant.
    if (widget.gate != null && !widget.gate!()) {
      _releaseReservationIfHeld(widget.featureId);
      return;
    }
    // Re-check `shouldShow` too: `_syncFromServer` may have completed
    // during the 3s pre-fire delay and marked this feature `disabled`
    // via the backoffice kill-switch. Without this check we'd honour
    // the `t=0` decision (when the server sync hadn't landed yet) and
    // fire a spotlight the server has since disabled.
    final service = ref.read(featureSpotlightServiceProvider.notifier);
    if (!service.shouldShow(widget.featureId)) {
      _releaseReservationIfHeld(widget.featureId);
      return;
    }
    // A modal (sheet/dialog) may have opened DURING the 3s pre-fire
    // window (this is the common case — user taps a save button and
    // the AddToListSheet slides up before the coachmark fires). Bail
    // and release the reservation; `_onModalCountChanged` re-arms when
    // the modal stack drains back to zero.
    if (spotlightModalObserver.activeModalCount.value > 0) {
      _releaseReservationIfHeld(widget.featureId);
      return;
    }
    // The target may have scrolled behind a persistent occluder during
    // the 3s delay. Release the slot and re-arm the poll rather than fire
    // a coach-mark the user can't fully see (PROD-2964).
    if (_isTargetOccluded()) {
      _releaseReservationIfHeld(widget.featureId);
      _ensureOcclusionRetry();
      return;
    }
    _cancelOcclusionRetry();

    final showcase = ShowCaseWidget.of(context);
    _started = true;
    showcase.startShowCase([_key]);
    _fireShownOnce();
    _insertHandOverlay();
  }

  void _insertHandOverlay() {
    if (_handOverlay != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _handOverlay = OverlayEntry(
      builder: (_) => SpotlightHandOverlay(
        targetKey: _targetKey,
        // The card's real rect drives which side the hand takes (opposite
        // the card). `tooltipPosition` is only the first-frame fallback,
        // used until the card lays out; it must still match the value
        // passed to `Showcase.withWidget` below (PROD-3294).
        tooltipCardKey: _tooltipCardKey,
        tooltipPosition: widget.tooltipPosition ?? TooltipPosition.bottom,
      ),
    );
    overlay.insert(_handOverlay!);
  }

  void _removeHandOverlay() {
    _handOverlay?.remove();
    _handOverlay = null;
  }

  void _fireShownOnce() {
    if (_shownAnalyticsFired) return;
    _shownAnalyticsFired = true;
    final def = spotlightForId(widget.featureId);
    if (def == null) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackSpotlightShown(featureId: def.id, surface: def.surface);
  }

  void _handleDismiss() {
    final def = spotlightForId(widget.featureId);
    if (def != null) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackSpotlightDismissed(featureId: def.id, surface: def.surface);
    }
    ShowCaseWidget.of(context).dismiss();
    _removeHandOverlay();
    // markSeen also clears the active-spotlight slot server-side; mirror
    // that in our local held-flag so `dispose` doesn't try to double-release.
    _reservationHeld = false;
    // Fire-and-forget markSeen — no need to block the dismissal on the
    // network round-trip; `_syncFromServer` reconciles on next load.
    ref
        .read(featureSpotlightServiceProvider.notifier)
        .markSeen(widget.featureId, FeatureSpotlightSeenReason.dismissed);
  }

  void _handleCtaTap() {
    final def = spotlightForId(widget.featureId);
    if (def != null) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackSpotlightCtaTapped(featureId: def.id, surface: def.surface);
    }
    // Dismiss BEFORE invoking the action so any sheet/dialog opened by
    // the action renders on top instead of underneath the spotlight scrim.
    ShowCaseWidget.of(context).dismiss();
    _removeHandOverlay();
    _reservationHeld = false;
    // Fire-and-forget — do not await so the action opens instantly.
    ref
        .read(featureSpotlightServiceProvider.notifier)
        .markSeen(widget.featureId, FeatureSpotlightSeenReason.ctaTapped);
    widget.onCtaAction?.call();
  }

  @override
  Widget build(BuildContext context) {
    final def = spotlightForId(widget.featureId);
    if (def == null) return widget.child;

    return Showcase.withWidget(
      key: _key,
      container: Builder(
        builder: (ctx) {
          final l10n = Lt.of(ctx);
          return SpotlightTooltip(
            cardKey: _tooltipCardKey,
            title: _resolve(l10n, def.titleKey),
            body: _resolve(l10n, def.bodyKey),
            ctaLabel: _resolve(l10n, def.ctaLabelKey),
            dismissLabel: l10n.spotlightDismissCta,
            illustrationAsset: def.illustrationAsset,
            content: widget.content,
            onCtaTapped: _handleCtaTap,
            onDismissed: _handleDismiss,
            // No CTA action = pure acknowledgment (e.g. message_feedback).
            // The primary CTA IS the dismiss — drop the redundant link
            // so the tooltip doesn't render two buttons with the same label.
            showDismissLink: widget.onCtaAction != null,
          );
        },
      ),
      // Dim the surrounding UI so the target reads as the focus, matching
      // the onboarding screen's full-page focus. Cutout around the target
      // stays fully lit.
      overlayColor: const Color(0xFF44131D),
      overlayOpacity: 0.55,
      targetShapeBorder: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(widget.targetCornerRadius),
      ),
      targetPadding: widget.targetPadding,
      // Force the tooltip BELOW the target so the Soko hand at the top
      // of the tooltip card points UP at the button. Overrides
      // `widget.tooltipPosition` when null (the default).
      tooltipPosition: widget.tooltipPosition ?? TooltipPosition.bottom,
      // A tap on the surrounding scrim (outside the card) dismisses the
      // spotlight, routed through `_handleDismiss` so it's recorded as a
      // `dismissed` end (same as the dismiss link). A tap on the
      // highlighted target itself still does nothing (`onTargetClick` is a
      // no-op with `disposeOnTap: false`) — only the dismiss button, the
      // CTA, or an outside/scrim tap close it. `disableBarrierInteraction`
      // MUST be false to pass `onBarrierClick` (showcaseview asserts the
      // two are mutually exclusive); the library calls `onBarrierClick`
      // then `_nextIfAny()`, but `_handleDismiss` has already torn the
      // showcase down so that follow-up is a no-op (no double-dismiss).
      disableBarrierInteraction: false,
      onBarrierClick: _handleDismiss,
      disposeOnTap: false,
      onTargetClick: () {},
      // KeyedSubtree lets the Soko hand overlay resolve the target's
      // RenderBox (via _targetKey) to place the hand adjacent to the
      // actual button — independent of where showcaseview puts the
      // tooltip card.
      //
      // The opaque Listener makes the target's whole rect hit-test as a
      // solid box, so the occlusion probe (`_isTargetOccluded`) can tell
      // "covered by chrome" apart from "target is see-through". Without
      // it, a non-interactive target (Text/Image) would let a probe hit
      // pass through to the background and read as permanently occluded —
      // the spotlight would silently never fire. For today's interactive
      // targets this is a no-op: it tests the child first (so the button's
      // own taps still work — `hitTestChildren || hitTestSelf`) and only
      // adds itself when the child doesn't claim the point (PROD-2964).
      child: KeyedSubtree(
        key: _targetKey,
        child: Listener(behavior: HitTestBehavior.opaque, child: widget.child),
      ),
    );
  }

  /// Resolve an ARB key by name via the generated `Lt` API.
  ///
  /// Uses a switch so the generated getter dispatch stays fully
  /// typed — dynamic access is not supported by the l10n gen.
  String _resolve(Lt l10n, String key) {
    switch (key) {
      case 'spotlightRemindersV1Title':
        return l10n.spotlightRemindersV1Title;
      case 'spotlightRemindersV1Body':
        return l10n.spotlightRemindersV1Body;
      case 'spotlightRemindersV1Cta':
        return l10n.spotlightRemindersV1Cta;
      case 'spotlightIgShareV1Title':
        return l10n.spotlightIgShareV1Title;
      case 'spotlightIgShareV1Body':
        return l10n.spotlightIgShareV1Body;
      case 'spotlightIgShareV1Cta':
        return l10n.spotlightIgShareV1Cta;
      case 'spotlightMapPageV1Title':
        return l10n.spotlightMapPageV1Title;
      case 'spotlightMapPageV1Body':
        return l10n.spotlightMapPageV1Body;
      case 'spotlightMapPageV1Cta':
        return l10n.spotlightMapPageV1Cta;
      case 'spotlightProfileV1Title':
        return l10n.spotlightProfileV1Title;
      case 'spotlightProfileV1Body':
        return l10n.spotlightProfileV1Body;
      case 'spotlightProfileV1Cta':
        return l10n.spotlightProfileV1Cta;
      default:
        return key;
    }
  }
}
