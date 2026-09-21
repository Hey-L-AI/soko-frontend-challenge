import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart' show SharedByUser, UserRole;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart' show currentUserProvider;
import '../../../shared/widgets/shared_by_attribution.dart';
import '../../profile/widgets/mutual_avatars_row.dart';
import 'sharers_sheet.dart';

/// Event attribution row that scales from one sharer to many (PROD-3160).
///
/// * 0 sharers → nothing (system/scraped events).
/// * 1 sharer → delegates to [SharedByAttribution] — the single tappable name
///   from PROD-3134, behaviour unchanged.
/// * 2+ sharers → an overlapping avatar cluster ([MutualAvatarsRow]) plus a
///   collapsed `Shared by A, B and others` label. Tapping the row opens the
///   [SharersSheet] popup listing every sharer as a profile link.
///
/// The per-sharer profile links live in the popup (admin-gated there, matching
/// PROD-3134); this row's whole hit area just opens the popup, so it stays
/// tappable for everyone.
class EventSharersAttribution extends ConsumerStatefulWidget {
  /// Head of the sharer list (up to 3), from `EventDetailOut.sharers_preview`.
  final List<SharedByUser> sharersPreview;

  /// Total distinct sharers, from `EventDetailOut.sharers_count`.
  final int sharersCount;

  /// Single-sharer primary (`shared_by`), used as a back-compat fallback when a
  /// backend predates `sharers_preview`/`sharers_count`.
  final SharedByUser? sharedBy;

  /// Event id — the popup pages `GET /app/events/{id}/shared-by` by it.
  final String eventId;

  const EventSharersAttribution({
    super.key,
    required this.sharersPreview,
    required this.sharersCount,
    required this.sharedBy,
    required this.eventId,
  });

  @override
  ConsumerState<EventSharersAttribution> createState() =>
      _EventSharersAttributionState();
}

class _EventSharersAttributionState
    extends ConsumerState<EventSharersAttribution> {
  static const _textStyle = TextStyle(
    fontFamily: 'ZalandoSans',
    fontWeight: FontWeight.w300,
    fontSize: 13,
    height: 1.2,
    letterSpacing: -0.13,
    color: AppColors.sokoShade1,
  );

  /// Display name: prefer full name, fall back to `@handle`, empty if neither.
  static String _displayName(SharedByUser u) {
    final fullName = u.fullName?.trim() ?? '';
    if (fullName.isNotEmpty) return fullName;
    final handle = u.handle?.trim() ?? '';
    return handle.isNotEmpty ? '@$handle' : '';
  }

  /// PROD-3168: shared_by_view fires once for the multi-sharer row. The single
  /// sharer case delegates to [SharedByAttribution], which tracks itself.
  bool _viewTracked = false;

  @override
  Widget build(BuildContext context) {
    // Prefer the multi-sharer preview; degrade to the single-sharer primary so
    // the row still renders against a backend that only sends `shared_by`.
    final preview = widget.sharersPreview.isNotEmpty
        ? widget.sharersPreview
        : (widget.sharedBy != null
              ? [widget.sharedBy!]
              : const <SharedByUser>[]);
    if (preview.isEmpty) return const SizedBox.shrink();

    // `sharers_count` is authoritative; fall back to the preview length when a
    // backend hasn't populated it yet.
    final count = widget.sharersCount > 0
        ? widget.sharersCount
        : preview.length;

    if (count <= 1) {
      return SharedByAttribution(
        sharedBy: preview.first,
        entityType: SharedByEntity.event,
        entityId: widget.eventId,
      );
    }

    final l10n = Lt.of(context);
    final names = preview
        .map(_displayName)
        .where((n) => n.isNotEmpty)
        .take(2)
        .toList();
    if (names.isEmpty) return const SizedBox.shrink();

    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;
    final viewerRole = isAdmin ? ViewerRole.admin : ViewerRole.user;

    if (!_viewTracked) {
      _viewTracked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(unifiedAnalyticsProvider)
            .trackSharedByView(
              entityType: SharedByEntity.event,
              entityId: widget.eventId,
              viewerRole: viewerRole,
              sharersCount: count,
            );
      });
    }

    // "Shared by A and B" when exactly two are named and no one remains;
    // otherwise "Shared by A, B and others".
    final text = (count == 2 && names.length == 2)
        ? l10n.sharedByTwoNames(names[0], names[1])
        : l10n.sharedByNamesAndOthers(names.join(', '));

    final row = MutualAvatarsRow(
      avatars: preview.map((u) => u.avatarUrl?.trim() ?? '').toList(),
      totalCount: count,
      text: text,
      textStyle: _textStyle,
      size: 20,
    );

    return Semantics(
      button: true,
      label: text,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            ref
                .read(unifiedAnalyticsProvider)
                .trackSharedByClick(
                  entityType: SharedByEntity.event,
                  entityId: widget.eventId,
                  viewerRole: viewerRole,
                  sharersCount: count,
                );
            showSharersSheet(
              context: context,
              ref: ref,
              eventId: widget.eventId,
              totalCount: count,
            );
          },
          child: row,
        ),
      ),
    );
  }
}
