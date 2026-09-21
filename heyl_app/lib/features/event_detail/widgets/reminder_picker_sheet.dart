import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/deep_link_redaction.dart';
import '../../../core/utils/event_time_formatter.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../core/utils/reminder_offset_label.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/event_occurrence.dart';
import '../../../data/models/event_reminder.dart';
import '../../notifications/widgets/my_reminders_sheet.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/notifications/notifications_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../entity_signals/providers/signal_controller.dart';

/// PROD-2525 T-K3 — "Lembrar-me" bottom sheet on event detail.
///
/// Multi-select chip picker over the canonical preset offsets
/// (15 min · 30 min · 1 h · 1 day · 1 week). On confirm:
///   * POSTs one `event-reminders` row per newly-selected offset
///   * DELETEs any previously-existing reminder whose offset was
///     unchecked
///
/// First-open behaviour: only the user's actually-saved reminders are
/// pre-selected. A fresh event (no saved reminders) opens with nothing
/// checked, and the Save button stays disabled until the user picks at
/// least one offset — the picker never seeds a default offset.
///
/// Multi-occurrence events get an inline occurrence selector at the
/// top of the sheet — **single-select** (radio) horizontal chip row.
/// Exactly one occurrence is selected at a time; tapping a chip
/// selects it and deselects the others, and the offset chips beneath
/// control reminders for that one occurrence. Reminders already saved
/// on other occurrences are preserved on save (they diff to a no-op) —
/// so a user can still build up multi-day reminders across taps, just
/// not in one action. Callers should pass only *upcoming* occurrences
/// (the chrome already gates the entry icon on `startAt > now`); past
/// occurrences should not appear here.
Future<bool?> showReminderPickerSheet({
  required BuildContext context,
  required String eventId,
  required List<EventOccurrence> upcomingOccurrences,
}) {
  assert(
    upcomingOccurrences.isNotEmpty,
    'showReminderPickerSheet requires at least one upcoming occurrence — '
    'the entry icon should be gated on the chrome side.',
  );
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    // Push onto the root navigator so the State's `Navigator.of(context,
    // rootNavigator: true).pop(...)` on Save reliably dismisses the
    // sheet — bypasses any intermediate shell-route navigator between
    // the modal and the sheet's content context.
    useRootNavigator: true,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: ReminderPickerSheet(
        eventId: eventId,
        upcomingOccurrences: upcomingOccurrences,
      ),
    ),
  );
}

class ReminderPickerSheet extends ConsumerStatefulWidget {
  final String eventId;
  final List<EventOccurrence> upcomingOccurrences;

  const ReminderPickerSheet({
    super.key,
    required this.eventId,
    required this.upcomingOccurrences,
  });

  @override
  ConsumerState<ReminderPickerSheet> createState() =>
      _ReminderPickerSheetState();
}

class _ReminderPickerSheetState extends ConsumerState<ReminderPickerSheet> {
  bool _loadingExisting = true;
  bool _saving = false;
  // Per-event state — keyed by `occurrence.id` so toggling the
  // occurrence chips doesn't wipe edits on a sibling occurrence, and the
  // "Vou-te lembrar …" preview can enumerate reminders across every
  // upcoming occurrence in one read.
  final Map<String, Map<int, EventReminder>> _existingByOccurrence = {};
  final Map<String, Set<int>> _selectedByOccurrence = {};
  // Single-select (radio): the one occurrence the offset chips currently
  // edit. Tapping a chip replaces this; the others' loaded state stays
  // in `_selectedByOccurrence` untouched so the save diff preserves any
  // reminders already saved on them. Never null while mounted — always
  // points at some id in `_sortedUpcoming`.
  late String _selectedOccurrenceId;
  late List<EventOccurrence> _sortedUpcoming;

  @override
  void initState() {
    super.initState();
    // Sort defensively so callers don't have to.
    _sortedUpcoming = [...widget.upcomingOccurrences]
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    // Pre-init the per-occurrence maps so every accessor is total — no
    // mid-flight `null` to guard against in `_hasPendingChanges` or the
    // preview.
    for (final occ in _sortedUpcoming) {
      _existingByOccurrence[occ.id] = {};
      _selectedByOccurrence[occ.id] = {};
    }
    // Default the selection to the soonest occurrence until
    // `_loadExisting` refines it based on what's saved on the server.
    _selectedOccurrenceId = _sortedUpcoming.first.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadExisting();
    });
  }

  void _onOccurrenceTap(EventOccurrence occurrence) {
    // Single-select: the tapped chip becomes the sole selection,
    // deselecting whatever was selected before. The previous
    // occurrence's chosen offsets stay in `_selectedByOccurrence` so
    // they're preserved (diff to no-op) unless the user comes back and
    // edits that day.
    setState(() => _selectedOccurrenceId = occurrence.id);
  }

  Future<void> _loadExisting() async {
    try {
      final api = ref.read(eventRemindersApiProvider);
      final list = await api.listForEvent(widget.eventId);
      if (!mounted) return;
      final upcomingIds = _sortedUpcoming.map((o) => o.id).toSet();
      // Bucket every pending reminder by its occurrence id — drop past
      // / fired / cancelled rows (the picker only edits upcoming).
      final byOccurrence = <String, List<EventReminder>>{};
      for (final r in list.items) {
        if (!r.isPending) continue;
        if (!upcomingIds.contains(r.eventOccurrenceId)) continue;
        (byOccurrence[r.eventOccurrenceId] ??= <EventReminder>[]).add(r);
      }
      setState(() {
        for (final occ in _sortedUpcoming) {
          final mine = byOccurrence[occ.id] ?? const <EventReminder>[];
          final existingMap = <int, EventReminder>{
            for (final r in mine) r.offsetMinutes: r,
          };
          _existingByOccurrence[occ.id] = existingMap;

          // Only the user's actually-saved reminders are pre-selected —
          // the picker never seeds a default offset on a fresh event, so
          // an event with no reminders opens with nothing checked and the
          // Save button stays disabled until the user picks one.
          final initial = mine.map((r) => r.offsetMinutes).toSet();
          // Drop any offset that would now fire in the past for this
          // occurrence — backend rejects those with 422 (a saved reminder
          // whose fire time has passed drops out and is cancelled on save).
          final minutesUntilStart = occ.startAt
              .difference(DateTime.now())
              .inMinutes;
          _selectedByOccurrence[occ.id] = initial
              .where((m) => m <= minutesUntilStart)
              .toSet();
        }
        // Pick the single default selection: the soonest occurrence
        // that ended up with any selection (saved or seeded), else the
        // soonest *renderable* occurrence (one that can still host a
        // preset offset or carries existing reminders), else — worst
        // case, every occurrence too close — the soonest. The offset
        // row will just render empty in that last case until the user
        // closes the sheet; the chrome entry gate is supposed to
        // prevent it.
        _selectedOccurrenceId = _sortedUpcoming
            .firstWhere(
              (o) => (_selectedByOccurrence[o.id] ?? const {}).isNotEmpty,
              orElse: () => _sortedUpcoming.firstWhere(
                _canHostReminder,
                orElse: () => _sortedUpcoming.first,
              ),
            )
            .id;
        _loadingExisting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingExisting = false;
      });
    }
  }

  /// Whether `offsetMinutes` would land `fire_at` in the future for the
  /// given `occurrence`. Matches the backend's 422 check
  /// (`occurrence.start_at − offset_minutes` must be in the future
  /// relative to now). Reads `DateTime.now()` each call rather than
  /// caching — the picker is short-lived but a tap on Save can still
  /// happen multiple seconds after first render.
  bool _isOffsetValidFor(EventOccurrence occurrence, int offsetMinutes) {
    return offsetMinutes <=
        occurrence.startAt.difference(DateTime.now()).inMinutes;
  }

  /// The currently-selected occurrence (single-select). Always resolves
  /// to a member of `_sortedUpcoming`.
  EventOccurrence get _selectedOccurrence =>
      _sortedUpcoming.firstWhere((o) => o.id == _selectedOccurrenceId);

  /// True iff `offsetMinutes` is valid (would fire in the future) for
  /// the selected occurrence. Drives whether a preset chip renders at
  /// all — once the occurrence's `startAt` is closer than the preset's
  /// offset, the chip is hidden.
  bool _isOffsetValidForSelected(int offsetMinutes) {
    return _isOffsetValidFor(_selectedOccurrence, offsetMinutes);
  }

  /// True iff `offsetMinutes` is currently selected on the selected
  /// occurrence — drives the chip's pink "selected" fill.
  bool _isOffsetSelectedOnSelected(int offsetMinutes) {
    return (_selectedByOccurrence[_selectedOccurrenceId] ?? const {}).contains(
      offsetMinutes,
    );
  }

  /// Whether `occurrence` can host any reminder right now — i.e. at
  /// least one preset offset is still valid for it (would fire in the
  /// future) OR it has pre-existing pending reminders the user might
  /// want to remove. Occurrences too close to fire even the shortest
  /// preset (15 min) and with no existing reminders aren't useful in
  /// the picker and are hidden from the chip row entirely.
  bool _canHostReminder(EventOccurrence occurrence) {
    for (final preset in ReminderOffset.presets) {
      if (_isOffsetValidFor(occurrence, preset.minutes)) return true;
    }
    return (_existingByOccurrence[occurrence.id] ?? const {}).isNotEmpty;
  }

  /// Occurrences worth surfacing in the chip row — the soonest ones
  /// whose `startAt` is too close for any preset (and that carry no
  /// pre-existing reminders) drop out, since the user can neither set
  /// nor edit anything on them. Computed dynamically off the loaded
  /// state so the row collapses correctly once `_loadExisting` lands.
  List<EventOccurrence> get _renderableOccurrences {
    return _sortedUpcoming.where(_canHostReminder).toList(growable: false);
  }

  /// True iff applying `_selectedByOccurrence` would result in any POST
  /// or DELETE — i.e. ANY occurrence's selected set differs from its
  /// existing-by-offset keys. Drives the Save button's enabled state so
  /// a user can't tap-to-no-op when they only picked the day
  /// (occurrence chip) without touching any offset chip.
  bool get _hasPendingChanges {
    for (final occ in _sortedUpcoming) {
      final selected = _selectedByOccurrence[occ.id] ?? const <int>{};
      final existing = (_existingByOccurrence[occ.id] ?? const {}).keys.toSet();
      if (selected.length != existing.length) return true;
      if (selected.any((m) => !existing.contains(m))) return true;
    }
    return false;
  }

  /// True iff the user has at least one pending reminder ANYWHERE on
  /// this event. Drives the preview prefix swap ("Atualmente tens …"
  /// vs "Vou-te lembrar …") and the subtitle hint.
  bool get _anyExistingForEvent {
    return _existingByOccurrence.values.any((m) => m.isNotEmpty);
  }

  /// Format an occurrence's start as the preview line uses it.
  ///   * Today / Tomorrow → `hoje às 18h` / `amanhã às 18h`
  ///     (the relative-day word + locale `às`/`at` + time, no `(dia N)`
  ///     clarifier needed because the word already locates the day)
  ///   * Other days → `Sáb (dia 22) às 18h` (short weekday + day-of-month
  ///     parenthetical + locale connector + time)
  ///   * `timeKnown: false` → drops the connector + time tail entirely.
  ///
  /// Mirrors the cap-on-day logic and short-weekday post-processing of
  /// [formatEventWhen] but builds a different sentence shape — so we
  /// don't reuse that helper directly here.
  String _formatPreviewDate(BuildContext context, EventOccurrence occ) {
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toString();
    final start = occ.startAt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDay = DateTime(start.year, start.month, start.day);
    final daysFromToday = startDay.difference(today).inDays;

    final timeStr = occ.timeKnown ? formatEventTime(start, locale) : null;
    final timeSuffix = timeStr == null
        ? ''
        : ' ${l10n.reminderPreviewTimeConnector} $timeStr';

    if (daysFromToday <= 0) {
      // Reuse the existing "Today" word from the discovery shelf l10n —
      // every locale already has it ("Hoje" / "Today"). Suffix the
      // locale `às`/`at` connector + time manually so the sentence
      // reads `hoje às 18h` rather than the shelf's `Hoje, 18h`.
      return '${l10n.discoveryShelfHappeningCardWhenTodayNoTime}$timeSuffix';
    }
    if (daysFromToday == 1) {
      return '${l10n.discoveryShelfHappeningCardWhenTomorrowNoTime}$timeSuffix';
    }
    // Short weekday: "Sáb" / "Sat" — title-case and strip the trailing
    // dot the intl pt-PT short pattern adds ("sex.") — same fixup
    // [formatEventWhen] applies. The `(dia N)` parenthetical anchors
    // the chip even for weekdays more than 7 days out (where two
    // future "Sábs" exist), so we use this branch for everything
    // beyond Tomorrow rather than falling back to the absolute date.
    final raw = DateFormat('EEE', locale).format(start).replaceAll('.', '');
    final weekday = raw.isEmpty
        ? raw
        : '${raw[0].toUpperCase()}${raw.substring(1)}';
    final dayParen = l10n.reminderPreviewDayParenthetical(start.day);
    return '$weekday $dayParen$timeSuffix';
  }

  /// Build the preview as a list of inline spans — a single line for the
  /// currently-selected occurrence and its valid (future-firing)
  /// selected offsets.
  ///
  /// Example (PT): `Evento Sáb (dia 22) às 18h: 30 min antes e 1d antes`
  ///
  /// Returns null when nothing survives (no offset selected on the
  /// selected occurrence, or every selected offset is invalid for it).
  List<InlineSpan>? _buildReminderPreviewSpans(BuildContext context, Lt l10n) {
    final occ = _selectedOccurrence;
    final selected = _selectedByOccurrence[occ.id] ?? const <int>{};
    final valid = selected.where((m) => _isOffsetValidFor(occ, m)).toList()
      ..sort();
    if (valid.isEmpty) return null;

    const boldStyle = TextStyle(fontWeight: FontWeight.w600);
    final prefixWord = l10n.reminderPreviewLinePrefix;
    final offsets = valid.map((m) => _labelForArbitrary(l10n, m)).toList();
    final spans = <InlineSpan>[];
    spans.add(TextSpan(text: '$prefixWord '));
    spans.add(
      TextSpan(text: _formatPreviewDate(context, occ), style: boldStyle),
    );
    spans.add(const TextSpan(text: ': '));
    for (var i = 0; i < offsets.length; i++) {
      spans.add(TextSpan(text: offsets[i]));
      if (i < offsets.length - 2) {
        spans.add(const TextSpan(text: ', '));
      } else if (i == offsets.length - 2) {
        spans.add(TextSpan(text: ' ${l10n.naturalListAnd} '));
      }
    }
    return spans;
  }

  /// Toggle an offset on the currently-selected occurrence:
  ///   * If it's selected → remove it.
  ///   * Otherwise → add it, but only if it would still fire in the
  ///     future for this occurrence (the chip's renderable check already
  ///     hides offsets invalid for the selected occurrence, so this
  ///     guard is belt-and-braces).
  void _toggleOffset(int offsetMinutes) {
    setState(() {
      final set = _selectedByOccurrence[_selectedOccurrenceId]!;
      if (set.contains(offsetMinutes)) {
        set.remove(offsetMinutes);
      } else if (_isOffsetValidFor(_selectedOccurrence, offsetMinutes)) {
        set.add(offsetMinutes);
      }
    });
  }

  Future<void> _onConfirm() async {
    if (_saving) return;

    // Guest gate: the picker itself is the explanation surface. On
    // Confirm, route the user to /login with the current URL stashed in
    // `returnUrlProvider`; `OAuthCallbackScreen` bounces them back to
    // this event page post-OAuth. Pop the sheet first so /login doesn't
    // sit under the picker overlay — and capture `router` + URI before
    // the pop because `context` becomes stale once the sheet unmounts.
    // Read the URI off `router` (not `GoRouterState.of(context)`), since
    // the sheet is mounted under the root Navigator's overlay — above
    // the GoRouter shell — so no GoRouterState is available here.
    if (!ref.read(isAuthenticatedProvider)) {
      final router = GoRouter.of(context);
      final currentUri = router.routeInformationProvider.value.uri;
      ref.read(returnUrlProvider.notifier).state = redactDeepLinkForLogging(
        currentUri,
      );
      Navigator.of(context, rootNavigator: true).pop(false);
      router.push('${AppRoutes.login}?from=${AuthReferrer.guestSetReminder}');
      return;
    }

    final l10n = Lt.of(context);

    // Per-occurrence diff against the saved state. Drives the no-op guard, the
    // action-aware toast copy, and the PROD-3209 reminder-lifecycle analytics.
    // The chip filters already prevent unsavable (past) offsets from staging.
    final perOccurrenceCreates = <EventOccurrence, List<int>>{};
    final perOccurrenceCancels = <EventOccurrence, List<String>>{};
    for (final occ in _sortedUpcoming) {
      final selected = _selectedByOccurrence[occ.id] ?? const <int>{};
      final existing = _existingByOccurrence[occ.id] ?? const {};
      perOccurrenceCreates[occ] = selected
          .where((m) => !existing.containsKey(m))
          .toList(growable: false);
      perOccurrenceCancels[occ] = existing.entries
          .where((e) => !selected.contains(e.key))
          .map((e) => e.value.id)
          .toList(growable: false);
    }
    final anyCreate = perOccurrenceCreates.values.any((l) => l.isNotEmpty);
    final anyCancel = perOccurrenceCancels.values.any((l) => l.isNotEmpty);
    if (!anyCreate && !anyCancel) {
      Navigator.of(context, rootNavigator: true).pop(false);
      return;
    }
    setState(() => _saving = true);

    // Action-aware toast copy: only POSTs → "set", only DELETEs → "removed",
    // mixed → generic "updated".
    final addedOnly = anyCreate && !anyCancel;
    final removedOnly = anyCancel && !anyCreate;
    final message = addedOnly
        ? l10n.reminderPickerSetToast
        : removedOnly
        ? l10n.reminderPickerRemovedToast
        : l10n.reminderPickerSavedToast;

    try {
      // PROD-3209: reminder lifecycle analytics.
      final analytics = ref.read(unifiedAnalyticsProvider);
      // The reminders API is THE going writer (#21). PUT the FULL desired set to
      // /events/{id}/reminders — the backend reconciles (create/keep/cancel) in
      // one atomic write, checkmarks `marked_going_at` iff non-empty, records
      // occurrence-level going marks, and returns the resolved signal. No
      // client-side diff-replay, no extra GET — seed the controller from the
      // response.
      final specs = <({String occurrenceId, int offsetMinutes})>[
        for (final occ in _sortedUpcoming)
          for (final m in (_selectedByOccurrence[occ.id] ?? const <int>{}))
            (occurrenceId: occ.id, offsetMinutes: m),
      ];
      final signal = await ref
          .read(eventRemindersApiProvider)
          .setConfig(widget.eventId, specs);
      if (!mounted) return;
      ref
          .read(
            signalControllerProvider((
              type: SignalEntityType.event,
              id: widget.eventId,
            )).notifier,
          )
          .applyGoing(signal);
      // The setConfig PUT is a bulk reconcile, so emit the PROD-3209
      // reminder-lifecycle events off the computed per-occurrence delta.
      for (final entry in perOccurrenceCreates.entries) {
        for (final offset in entry.value) {
          analytics.trackReminderSet(
            entityId: widget.eventId,
            entityType: 'event',
            offsetMinutes: offset,
            occurrenceId: entry.key.id,
          );
        }
      }
      for (final entry in perOccurrenceCancels.entries) {
        for (final reminderId in entry.value) {
          analytics.trackReminderCancelled(
            reminderId: reminderId,
            entityId: widget.eventId,
          );
        }
      }
      if (!mounted) return;
      ref
          .read(notificationsProvider.notifier)
          .show(message: message, variant: SokoVariant.success);
      Navigator.of(context, rootNavigator: true).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ref
          .read(notificationsProvider.notifier)
          .show(
            message: l10n.reminderPickerSaveError,
            variant: SokoVariant.error,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.sokoInk8,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                const Icon(
                  LucideIcons.bell_ring,
                  color: AppColors.sokoInk,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.reminderPickerTitle,
                    style: const TextStyle(
                      color: AppColors.sokoInk,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              // Subtitle adapts based on whether the event has ANY
              // existing reminders — the "tap-to-remove" hint applies
              // whenever the user might land on a pink chip on any
              // occurrence tab.
              _anyExistingForEvent
                  ? l10n.reminderPickerSubtitleWithExisting
                  : l10n.reminderPickerSubtitle,
              style: const TextStyle(
                color: AppColors.sokoShade3,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            // Web has no FCM push channel today — the reminder still
            // fires (the backend fans out to every registered mobile
            // device for the user), but the browser will never see the
            // notification. Tell the user where it'll actually land so
            // the bell on web isn't misleading. Remove this block when
            // real web push lands (service worker + VAPID + backend
            // `platform: 'web'` enum).
            if (kIsWeb) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      LucideIcons.info,
                      size: 12,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.reminderPickerWebMobileOnlyHint,
                      style: const TextStyle(
                        color: AppColors.sokoShade3,
                        fontSize: 12,
                        height: 1.35,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            // Occurrence selector — only renders when at least two
            // *renderable* upcoming occurrences exist (i.e. each can
            // still host at least one preset offset, or already carries
            // pre-existing reminders). Single renderable occurrence
            // collapses to no chrome (the sheet keeps its previous
            // compact layout).
            if (_renderableOccurrences.length > 1) ...[
              const SizedBox(height: 16),
              _SectionLabel(text: l10n.reminderPickerOccurrencesLabel),
              const SizedBox(height: 8),
              _OccurrenceSelector(
                occurrences: _renderableOccurrences,
                selectedId: _selectedOccurrenceId,
                onTap: _onOccurrenceTap,
              ),
            ],
            const SizedBox(height: 16),
            if (_loadingExisting)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppColors.sokoInk),
                    ),
                  ),
                ),
              )
            else if (_renderableOccurrences.isEmpty &&
                !_anyExistingForEvent) ...[
              // Defensive empty state — the chrome's bell-tap gate
              // (event_detail_body.dart) normally prevents this, but
              // covers the race where time passes between the tap and
              // the sheet mount on an event that was just-barely
              // hostable. Same copy / voice as the toast.
              _NothingActionableEmptyState(
                text: l10n.reminderPickerNothingActionableEmptyState,
              ),
            ] else ...[
              _SectionLabel(text: l10n.reminderPickerOffsetsLabel),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // Mirror the BE's 422 rule: an offset that would
                  // place fire_at in the past for the selected
                  // occurrence is unsavable, so we hide it entirely
                  // rather than offer a dead chip. The selector adapts
                  // as the user selects a later occurrence (more chips
                  // become valid).
                  for (final preset in ReminderOffset.presets)
                    if (_isOffsetValidForSelected(preset.minutes))
                      _OffsetChip(
                        label: _labelForPreset(l10n, preset),
                        selected: _isOffsetSelectedOnSelected(preset.minutes),
                        onTap: () => _toggleOffset(preset.minutes),
                      ),
                  // Pre-existing reminders saved with a custom (non-preset)
                  // offset — surface them as toggle-removable chips so the
                  // user can still cancel them now that the custom input
                  // is gone. New custom offsets can't be created here
                  // anymore; the preset set covers the supported choices.
                  // These stay tappable even when invalid for the active
                  // occurrences — the user must be able to UNSELECT them
                  // to cancel the existing reminder (DELETE doesn't 422
                  // on past fire_at).
                  for (final custom in _nonPresetSelectionsForSelected())
                    _OffsetChip(
                      label: _labelForArbitrary(l10n, custom),
                      selected: true,
                      onTap: () => _toggleOffset(custom),
                    ),
                ],
              ),
            ],
            // "Vou-te lembrar …" recap so the user sees the exact wall-
            // clock fire times they're about to commit to. Only renders
            // when at least one selected offset is valid for the current
            // occurrence — empty selections + past-only chips collapse.
            // Dates render bold so the absolute fire times pop against
            // the surrounding sentence chrome.
            if (!_loadingExisting)
              Builder(
                builder: (context) {
                  final spans = _buildReminderPreviewSpans(context, l10n);
                  if (spans == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text.rich(
                      TextSpan(children: spans),
                      style: const TextStyle(
                        color: AppColors.sokoShade3,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  );
                },
              ),
            const SizedBox(height: 20),
            SokoCtaButton(
              label: _saving
                  ? l10n.reminderPickerSaving
                  : l10n.reminderPickerSave,
              // Disable until the diff against `_existingByOffset` is
              // non-empty — picking only the day (occurrence chip) is
              // not enough; the user must select at least one offset
              // (or deselect an existing one) for Save to fire an
              // actual POST/DELETE.
              onPressed: (_saving || _loadingExisting || !_hasPendingChanges)
                  ? null
                  : _onConfirm,
            ),
            // When the event already has saved reminders, offer a jump to
            // the user's full "my reminders" surface (where they can see /
            // remove reminders across every event).
            if (!_loadingExisting && _anyExistingForEvent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _openMyReminders,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 8,
                        ),
                        child: Text(
                          l10n.reminderPickerViewMyReminders,
                          style: const TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: AppColors.sokoInk,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Selected offsets on the selected occurrence that aren't part of the
  /// preset list — only surfaces pre-existing reminders saved with a
  /// custom offset (e.g. from a previous build that exposed the custom
  /// input). New custom values can't be created here anymore, but legacy
  /// ones stay toggle-removable until the user deselects them.
  Iterable<int> _nonPresetSelectionsForSelected() {
    final presetMinutes = ReminderOffset.presets.map((p) => p.minutes).toSet();
    final all = <int>{};
    for (final m
        in _selectedByOccurrence[_selectedOccurrenceId] ?? const <int>{}) {
      if (!presetMinutes.contains(m)) all.add(m);
    }
    return all;
  }

  /// Close the picker and open the user's "my reminders" sheet. Capture a
  /// context that survives the pop (the root navigator's own context)
  /// before popping — the sheet's own `context` is defunct afterwards.
  /// Mirrors the pop-then-navigate discipline in `_onConfirm`.
  void _openMyReminders() {
    final rootNav = Navigator.of(context, rootNavigator: true);
    final hostContext = rootNav.context;
    rootNav.pop(false);
    showMyRemindersSheet(hostContext, surface: 'event_reminder_picker');
  }

  String _labelForPreset(Lt l10n, ReminderOffset preset) {
    return _labelForArbitrary(l10n, preset.minutes);
  }

  String _labelForArbitrary(Lt l10n, int minutes) =>
      reminderOffsetLabel(l10n, minutes);
}

/// Horizontal **single-select** (radio) chip row for picking which
/// occurrence the reminders apply to. Used inside the picker sheet only
/// when there are 2+ upcoming occurrences. Labels reuse `formatEventWhen`
/// so the date chrome matches event cards everywhere else (Today/
/// Tomorrow/weekday/absolute date, locale-aware). Tapping a chip selects
/// it; exactly one chip is selected at a time.
class _OccurrenceSelector extends StatelessWidget {
  final List<EventOccurrence> occurrences;
  final String selectedId;
  final void Function(EventOccurrence) onTap;

  const _OccurrenceSelector({
    required this.occurrences,
    required this.selectedId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Horizontal scroller so a recurring event with many upcoming dates
    // doesn't blow the sheet width — the row stays one line.
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: occurrences.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final occurrence = occurrences[index];
          return _OccurrenceChip(
            label: formatEventWhen(
              context: context,
              startsAt: occurrence.startAt,
              timeKnown: occurrence.timeKnown,
            ),
            selected: occurrence.id == selectedId,
            onTap: () => onTap(occurrence),
          );
        },
      ),
    );
  }
}

/// Small section heading rendered above the occurrence and offset chip
/// rows. Same muted treatment as the sheet subtitle but with a slightly
/// heavier weight so it reads as a structural label rather than body
/// copy.
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.sokoShade3,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        height: 1.35,
      ),
    );
  }
}

/// In-sheet empty state shown when the picker has nothing actionable
/// to render — every upcoming occurrence is within the smallest preset
/// reminder window AND there are no pre-existing reminders. Centered
/// bell + muted body copy, same shape as the empty state on
/// `MyRemindersSheet` so the two read as the same family.
class _NothingActionableEmptyState extends StatelessWidget {
  final String text;
  const _NothingActionableEmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.bell, color: AppColors.sokoShade3, size: 28),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _OffsetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OffsetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? AppColors.sokoPink : AppColors.sokoPaper;
    // Offset chips are borderless in both states — the selected pink
    // fill alone carries the "on" reading. The soko-ink outline is
    // reserved for the occurrence selector above, where it marks the
    // single selected day.
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

/// Chip used by the occurrence selector at the top of the reminder
/// sheet. Rectangular (6px radius) so it reads distinctly from the
/// pill-shaped `_OffsetChip` row beneath — two different controls, two
/// different silhouettes.
///
/// Two visual states (single-select — exactly one chip selected):
///   * `selected` → pink fill + soko-ink border (the chosen day)
///   * `!selected` → paper fill, no border
class _OccurrenceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OccurrenceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? AppColors.sokoPink : AppColors.sokoPaper;
    // The selected chip carries both the pink fill and the soko-ink
    // outline so the one chosen day reads unambiguously.
    final border = selected ? AppColors.sokoInk : Colors.transparent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
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
