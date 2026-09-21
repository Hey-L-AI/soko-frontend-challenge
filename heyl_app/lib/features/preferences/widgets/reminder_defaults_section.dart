import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/event_reminder.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/preferences_provider.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/notifications/notifications_provider.dart';

/// PROD-2525 T-K3 — user-defaults editor for the auto-seeded reminder
/// offsets. Toggles the same preset chips the per-event picker uses
/// (15 min · 30 min · 1 h · 1 day · 1 week). Every chip tap PATCHes
/// `/users/me/preferences { default_reminder_offsets_minutes: int[] }`
/// so the selection persists immediately — same UX as the per-category
/// switches below it. Empty set = opt-out (server stops auto-seeding).
class ReminderDefaultsSection extends ConsumerWidget {
  const ReminderDefaultsSection({super.key});

  // Backend cap on `default_reminder_offsets_minutes` is 8 entries
  // (`maxItems: 8` per the OpenAPI schema). The section only exposes 5
  // preset chips today so the limit is unreachable from the UI, but
  // guard defensively in case we ever add presets or a custom entry
  // here — a silent 422 from the server would surface as the generic
  // save-error toast and the user wouldn't know why.
  static const int _maxDefaultOffsets = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final prefsState = ref.watch(preferencesProvider);
    final current = prefsState.preferences?.defaultReminderOffsetsMinutes;
    // Three-state contract from the OpenAPI spec
    // (`UserPreferences.default_reminder_offsets_minutes`):
    //
    // - `current == null` (never set) → light up the system fallback
    //   `{60, 1440}` so the UI mirrors what the server would seed at
    //   event-save time. Tapping any chip from this state transitions
    //   the server-side value from `null` → an explicit array.
    // - `current == []` (opted out) → empty set, no chips lit.
    // - non-empty list → those chips lit.
    //
    // Deselecting the last chip PATCHes `[]` (opt-out).
    //
    // Selection is derived from the provider on every build (no local
    // cache), so a fresh `load()` after re-entering the screen — or any
    // out-of-band update to preferences — is reflected immediately.
    final selected = current?.toSet() ?? const <int>{60, 1440};
    final isSaving = prefsState.isSaving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              LucideIcons.bell_ring,
              color: AppColors.sokoInk,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.reminderDefaultsTitle,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.reminderDefaultsSubtitle,
          style: const TextStyle(
            color: AppColors.sokoShade3,
            fontSize: 13,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in ReminderOffset.presets)
              _OffsetChip(
                label: _labelForArbitrary(l10n, preset.minutes),
                selected: selected.contains(preset.minutes),
                onTap: isSaving
                    ? null
                    : () => _toggle(ref, context, selected, preset.minutes),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l10n.reminderDefaultsOptOutHint,
          style: const TextStyle(
            color: AppColors.sokoShade3,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      ],
    );
  }

  Future<void> _toggle(
    WidgetRef ref,
    BuildContext context,
    Set<int> current,
    int minutes,
  ) async {
    final next = {...current};
    if (next.contains(minutes)) {
      next.remove(minutes);
    } else if (next.length < _maxDefaultOffsets) {
      next.add(minutes);
    } else {
      // At cap and the tapped chip is unselected — no-op.
      return;
    }
    final sorted = next.toList()..sort();
    final ok = await ref
        .read(preferencesProvider.notifier)
        .update(defaultReminderOffsetsMinutes: sorted);
    if (ok || !context.mounted) return;
    final l10n = Lt.of(context);
    final backendError = ref.read(preferencesProvider).error;
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: backendError ?? l10n.reminderDefaultsSaveError,
          variant: SokoVariant.error,
        );
  }

  String _labelForArbitrary(Lt l10n, int minutes) {
    if (minutes < 60) return l10n.reminderOffsetMinutes(minutes);
    if (minutes < 1440) {
      final hours = minutes ~/ 60;
      if (minutes - hours * 60 == 0) return l10n.reminderOffsetHours(hours);
    }
    if (minutes < 10080) {
      final days = minutes ~/ 1440;
      if (minutes - days * 1440 == 0) return l10n.reminderOffsetDays(days);
    }
    final weeks = minutes ~/ 10080;
    if (minutes - weeks * 10080 == 0 && weeks >= 1) {
      return l10n.reminderOffsetWeeks(weeks);
    }
    return l10n.reminderOffsetMinutes(minutes);
  }
}

class _OffsetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _OffsetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? AppColors.sokoPink : AppColors.sokoPaper;
    final border = selected ? AppColors.sokoPink : AppColors.sokoInk8;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border, width: 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.sokoInk,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
