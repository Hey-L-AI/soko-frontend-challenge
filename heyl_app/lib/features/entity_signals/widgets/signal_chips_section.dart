import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/entity_signal.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart' show isAuthenticatedProvider;
import '../../../shared/widgets/detail_action_button.dart';
import '../providers/signal_controller.dart';
import '../../../shared/widgets/soko_toggle_glyph.dart';

/// Sentiment thumbs (👍 Gosto / 👎 Isto não) for the venue/event detail action
/// row (PROD-2929). A thumb writes pure taste — `like` / `dislike` — and never
/// asserts attendance; `went` is a separate axis set elsewhere.
///
/// Returned as loose cells (not a wrapping Row) so the parent action row spaces
/// all five buttons — Guarda · Lembrete · Partilha · 👍 · 👎 — evenly full-width.
/// Auth-gated: returns `[]` (nothing) for signed-out users.
///
/// [provenance] is the surface attribution sent with the write (see
/// [SignalProvenance]). It is **required, deliberately not defaulted**: the
/// failure mode of a default is a new surface silently reporting someone else's
/// label, which is invisible in the app and only shows up as quietly wrong
/// analytics — the exact thing this attribution exists to prevent. Making the
/// compiler ask costs one argument.
///
/// Call inside a [Consumer] so the cells rebuild as the signal state changes.
List<Widget> signalThumbCells(
  BuildContext context,
  WidgetRef ref, {
  required SignalEntityType entityType,
  required String entityId,
  required String provenance,
  bool closeOnSignal = false,
}) {
  // Auth-gated. Checked before watching the controller so no request fires
  // for signed-out users.
  if (!ref.watch(isAuthenticatedProvider)) return const [];

  final key = (type: entityType, id: entityId);
  final state = ref.watch(signalControllerProvider(key));
  // Render immediately in the (unselected) outline state — don't gate on the
  // initial GET, or the thumbs pop in a beat after Save/Remind/Share. `taste`
  // is `none` until the GET lands, then the cells rebuild to the selected look.
  final taste = state.signal.taste;

  // Server owns the toggle — re-sending the held sentiment clears it. Fire only
  // when it changes; the controller reconciles to the returned state.
  void tap(SignalAction action) {
    // Whether this tap SETS a sentiment (vs toggling the held one back off) —
    // mirrors the server's toggle. Only a set closes the detail.
    final willSet = action == SignalAction.like
        ? taste != SignalTaste.liked
        : taste != SignalTaste.disliked;
    ref
        .read(signalControllerProvider(key).notifier)
        .apply(action, provenance: provenance);
    // When this detail is a pushed/sheet route (not the embedded in-list card),
    // setting a 👍/👎 closes it so the user drops back to the surface they came
    // from — a quick triage gesture. Re-tapping to CLEAR a sentiment keeps the
    // detail open. `apply` is optimistic (paints before the round-trip) and is
    // dispose-safe, so popping mid-write is fine; a card behind that watches the
    // same controller keeps it alive to reconcile.
    if (closeOnSignal && willSet) {
      Navigator.of(context).maybePop();
    }
  }

  // Selected → solid Soko Ink fill (same dark filled treatment as Save);
  // unselected → thin ink outline. (👎 is the 👍 glyph rotated 180°.)
  // Caption goes past-tense when held: Like → Liked. 👎 stays "Not for me"
  // (already a held stance, no natural past tense).
  return [
    DetailActionButton(
      label: taste == SignalTaste.liked
          ? Lt.of(context).signalLiked
          : Lt.of(context).signalLike,
      icon: _thumb(selected: taste == SignalTaste.liked),
      onTap: () => tap(SignalAction.like),
      popOnTap: true,
    ),
    DetailActionButton(
      label: Lt.of(context).signalThumbDown,
      icon: _thumb(selected: taste == SignalTaste.disliked, flip: true),
      onTap: () => tap(SignalAction.dislike),
      popOnTap: true,
    ),
  ];
}

/// A thumb glyph that cross-fades its fill in/out on selection instead of
/// snapping between two assets. The ink outline is always drawn; the solid
/// Soko Ink FILLED variant fades over it when [selected]. [flip] rotates 180°
/// for 👎.
Widget _thumb({required bool selected, bool flip = false}) {
  final stack = SizedBox(
    width: 26,
    height: 26,
    child: Stack(
      alignment: Alignment.center,
      children: [
        SvgPicture.asset(
          SokoToggleGlyph.thumbUpOutline,
          width: 26,
          height: 26,
          colorFilter: const ColorFilter.mode(
            AppColors.sokoInk,
            BlendMode.srcIn,
          ),
        ),
        AnimatedOpacity(
          opacity: selected ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: SvgPicture.asset(
            SokoToggleGlyph.thumbUpFill,
            width: 26,
            height: 26,
            colorFilter: const ColorFilter.mode(
              AppColors.sokoInk,
              BlendMode.srcIn,
            ),
          ),
        ),
      ],
    ),
  );
  return flip ? Transform.rotate(angle: 3.14159265, child: stack) : stack;
}
