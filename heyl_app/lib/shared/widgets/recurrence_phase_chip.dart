import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/recurrence_phase.dart';
import '../../l10n/generated/l10n.dart';
import 'soko_tag.dart';

/// PROD-3379 — a small reusable chip that renders a confident recurrence phase
/// ("Primeiros dias" / "Últimos dias"). Built on [SokoTag] so it matches the app's pill
/// chrome (radius 2, Zalando Sans Light, Soko/Ink label).
///
/// Deliberately surface-agnostic: the map results drawer cards, the event
/// detail sheet, and (later) the "This Week" / Happening cards all render the
/// same chip from their own `recurrence_phase` data — so the phase→label→colour
/// mapping lives here, once.
///
/// **Colour is an FE choice** (the ticket delegates visual treatment to FE; no
/// Figma comp): novelty → [AppColors.sokoYellow], last-chance →
/// [AppColors.sokoRed] (urgency). Both read on the drawer card artwork and the
/// green ([AppColors.sokoEvent]) detail sheet, and stay distinct from the blue
/// type pill. Logged in `docs/ui/design-decisions.md`.
class RecurrencePhaseChip extends StatelessWidget {
  const RecurrencePhaseChip({
    super.key,
    required this.phase,
    this.compact = false,
  });

  final RecurrencePhase phase;

  /// Use [SokoTag.textStyleCompact] (12 px) for tight card layouts; defaults to
  /// the standard 14 px [SokoTag.textStyle].
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    final String label;
    final Color background;
    switch (phase) {
      case RecurrencePhase.newRun:
        label = l10n.recurrencePhaseNew;
        background = AppColors.sokoYellow;
      case RecurrencePhase.lastDays:
        label = l10n.recurrencePhaseLastDays;
        background = AppColors.sokoRed;
    }

    return SokoTag(
      background: background,
      child: Text(
        label,
        style: compact ? SokoTag.textStyleCompact : SokoTag.textStyle,
      ),
    );
  }
}
