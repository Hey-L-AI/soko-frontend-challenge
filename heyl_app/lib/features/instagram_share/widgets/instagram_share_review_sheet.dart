import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/chat_message.dart' show ItemSuggestion;
import '../../../data/models/instagram_share.dart';
import '../../../data/models/social_proof.dart' show VenueDetailResponse;
import '../../../data/models/user_list.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart' show detailApiProvider;
import '../../../providers/lists_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/chat_items_picker_sheet.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../lists/providers/unified_list_provider.dart';
import '../providers/instagram_share_polling_provider.dart';

/// Show the post-completion review sheet for an Instagram share that produced
/// multiple events (and optionally a venue).
///
/// Operates against a "primary" list — the share's `target_list_id` when
/// shared from inside a list, falling back to the user's auto "From Instagram"
/// list otherwise. Default-checks every event; on confirm, unchecked events
/// are removed from the primary list AND cascade-removed from the auto
/// "From Instagram" list when it's a separate list (events are auto-added
/// to both at share time, so review must clean up both).
///
/// When `classification == 'event_announcement'` and `venue_id` is non-null,
/// an additional venue row is offered (default-checked) — confirm adds it to
/// the primary list.
Future<void> showInstagramShareReviewSheet({
  required BuildContext context,
  required WidgetRef ref,
  required SharedPostOut share,
  String? targetListId,
}) {
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (_) =>
        _InstagramShareReviewSheet(share: share, targetListId: targetListId),
  );
}

class _InstagramShareReviewSheet extends ConsumerStatefulWidget {
  final SharedPostOut share;
  final String? targetListId;

  const _InstagramShareReviewSheet({
    required this.share,
    required this.targetListId,
  });

  @override
  ConsumerState<_InstagramShareReviewSheet> createState() =>
      _InstagramShareReviewSheetState();
}

class _InstagramShareReviewSheetState
    extends ConsumerState<_InstagramShareReviewSheet> {
  bool _loadingItems = true;
  bool _saving = false;

  /// One display row per `event_id` in the share, in `event_ids` order.
  /// Source = target list when present, falling back to "From Instagram"
  /// otherwise. Events that exist in neither list (re-open after the user
  /// unchecked + confirmed earlier) are dropped from the picker — the
  /// rendering data isn't recoverable without an extra fetch.
  List<UserListItem> _displayItems = const [];

  /// Checked event ids. Default-populated based on whether each event is
  /// present in the user's chosen surface (target list when set, else FI).
  final Set<String> _keepEventIds = {};

  /// Where rows are rendered from. Equals `widget.targetListId` when set,
  /// else the resolved "From Instagram" list id, else null (if neither
  /// resolves we render an empty body the user can cancel out of).
  String? _primaryListId;

  /// The "other" list — auto "From Instagram" when primary is the user's
  /// target list, else null. Operations on primary are mirrored here so
  /// both lists stay in sync per the share contract.
  String? _cascadeListId;

  /// `event_id → user_list_item.id` for items currently in the primary list.
  Map<String, String> _primaryItemIdByEventId = const {};

  /// `event_id → user_list_item.id` for items currently in the cascade list.
  Map<String, String> _cascadeItemIdByEventId = const {};

  bool get _venueRowApplicable =>
      widget.share.classification == 'event_announcement' &&
      widget.share.venueId != null;

  bool _venueAlreadyInList = false;
  bool _venueLoading = false;
  VenueDetailResponse? _venueDetail;
  bool _addVenue = true;

  @override
  void initState() {
    super.initState();
    // Defer to post-frame: Lt.of(context) reads inherited widgets, which
    // cannot be touched until initState finishes. Calling _bootstrap()
    // synchronously here triggers a "called before initState completed"
    // assertion on the first Lt.of(context) read — see
    // docs/learnings/flutter-initstate-async-inherited-widget.md.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bootstrap();
    });
  }

  Future<void> _bootstrap() async {
    try {
      final lists = ref.read(listsProvider).lists;
      final fromInsta = _findInstagramList(lists);
      final fromInstaListId = fromInsta?.id;

      // Primary = the share's target list when set, else From Instagram.
      // No bail when neither resolves — render an empty body the user
      // can cancel out of, but never throw mid-init.
      final primaryListId = widget.targetListId ?? fromInstaListId;
      if (primaryListId == null) {
        if (!mounted) return;
        setState(() => _loadingItems = false);
        return;
      }

      // Cascade = the OTHER list. Null when primary IS FI, when no FI
      // was found, or when target equals FI.
      final cascadeListId =
          (fromInstaListId != null && fromInstaListId != primaryListId)
          ? fromInstaListId
          : null;

      await ref
          .read(unifiedListProvider(primaryListId).notifier)
          .loadItemsQuietly();
      if (!mounted) return;
      final primaryState = ref.read(unifiedListProvider(primaryListId));

      UnifiedListState? cascadeState;
      if (cascadeListId != null) {
        await ref
            .read(unifiedListProvider(cascadeListId).notifier)
            .loadItemsQuietly();
        if (!mounted) return;
        cascadeState = ref.read(unifiedListProvider(cascadeListId));
      }

      final eventIdSet = widget.share.eventIds.toSet();

      final primaryItemByEventId = <String, UserListItem>{
        for (final i in primaryState.items)
          if (i.eventId != null && eventIdSet.contains(i.eventId))
            i.eventId!: i,
      };
      final cascadeItemByEventId = <String, UserListItem>{
        if (cascadeState != null)
          for (final i in cascadeState.items)
            if (i.eventId != null && eventIdSet.contains(i.eventId))
              i.eventId!: i,
      };

      // Build display rows in event_ids order. Prefer the primary list's
      // item (the user's curated surface); fall back to cascade so we can
      // still render rows that briefly fell off primary (e.g. backend
      // mid-write race). Events in neither list are skipped — they were
      // already removed and we don't have rendering data without an
      // extra fetch.
      final displayItems = <UserListItem>[];
      final defaultKeep = <String>{};
      for (final eventId in widget.share.eventIds) {
        final item =
            primaryItemByEventId[eventId] ?? cascadeItemByEventId[eventId];
        if (item == null) continue;
        displayItems.add(item);
        // Default-check on presence in primary (the user's surface).
        // Re-opening after a partial removal therefore shows real state,
        // not a force-checked default that would silently re-add.
        if (primaryItemByEventId.containsKey(eventId)) {
          defaultKeep.add(eventId);
        }
      }

      // Venue presence checked against primary.
      final venueAlreadyInList =
          widget.share.venueId != null &&
          primaryState.items.any((i) => i.venueId == widget.share.venueId);

      if (!mounted) return;
      setState(() {
        _primaryListId = primaryListId;
        _cascadeListId = cascadeListId;
        _primaryItemIdByEventId = {
          for (final entry in primaryItemByEventId.entries)
            entry.key: entry.value.id,
        };
        _cascadeItemIdByEventId = {
          for (final entry in cascadeItemByEventId.entries)
            entry.key: entry.value.id,
        };
        _displayItems = displayItems;
        _keepEventIds.addAll(defaultKeep);
        _venueAlreadyInList = venueAlreadyInList;
        _loadingItems = false;
      });

      if (_venueRowApplicable && !venueAlreadyInList) {
        _fetchVenue();
      }
    } catch (e, st) {
      // Surface the error to the dev console (skipped in release builds)
      // so future asserts never re-vanish into a swallowed catch like the
      // initState/inherited-widget bug did. See
      // docs/learnings/flutter-initstate-async-inherited-widget.md.
      debugPrint('[ReviewSheet] bootstrap error: $e\n$st');
      if (!mounted) return;
      setState(() => _loadingItems = false);
    }
  }

  UserList? _findInstagramList(List<UserList> lists) {
    for (final list in lists) {
      if (list.isFromInstagramShare) return list;
    }
    return null;
  }

  Future<void> _fetchVenue() async {
    setState(() => _venueLoading = true);
    try {
      final detail = await ref
          .read(detailApiProvider)
          .getVenueDetail(widget.share.venueId!);
      if (!mounted) return;
      setState(() {
        _venueDetail = detail;
        _venueLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _venueLoading = false;
        _addVenue = false;
      });
    }
  }

  bool get _venueRowVisible => _venueRowApplicable && !_venueAlreadyInList;

  Future<void> _onConfirm() async {
    if (_saving) return;
    final primaryListId = _primaryListId;
    if (primaryListId == null) return;
    setState(() => _saving = true);

    final l10n = Lt.of(context);
    final navigator = Navigator.of(context);

    final primaryNotifier = ref.read(
      unifiedListProvider(primaryListId).notifier,
    );
    final cascadeListId = _cascadeListId;
    final cascadeNotifier = cascadeListId != null
        ? ref.read(unifiedListProvider(cascadeListId).notifier)
        : null;

    // Display items keyed by event_id — needed when re-checking an event
    // requires building an ItemSuggestion for the add-back path.
    final displayByEventId = <String, UserListItem>{
      for (final i in _displayItems)
        if (i.eventId != null) i.eventId!: i,
    };

    int keptCount = 0;

    // Two-pass: first compute which events to add vs. remove on primary AND
    // cascade, then issue one bulk-delete per list (PROD-1722) instead of N
    // parallel DELETEs. Adds still go through the optimistic path because
    // there's no bulk-add equivalent and the per-list rate limit isn't the
    // bottleneck for adds.
    final primaryRemoveIds = <String>[];
    final cascadeRemoveIds = <String>[];
    final primaryAddSrcs = <UserListItem>[];
    final cascadeAddSrcs = <UserListItem>[];

    for (final eventId in widget.share.eventIds) {
      final keep = _keepEventIds.contains(eventId);
      final inPrimary = _primaryItemIdByEventId.containsKey(eventId);
      final inCascade = _cascadeItemIdByEventId.containsKey(eventId);
      if (keep) keptCount++;

      if (keep && !inPrimary) {
        final src = displayByEventId[eventId];
        if (src != null) primaryAddSrcs.add(src);
      } else if (!keep && inPrimary) {
        primaryRemoveIds.add(_primaryItemIdByEventId[eventId]!);
      }

      if (cascadeNotifier != null && cascadeListId != null) {
        if (keep && !inCascade) {
          final src = displayByEventId[eventId];
          if (src != null) cascadeAddSrcs.add(src);
        } else if (!keep && inCascade) {
          cascadeRemoveIds.add(_cascadeItemIdByEventId[eventId]!);
        }
      }
    }

    // Bulk-delete on each list (one call per list — replaces the previous
    // N-parallel-DELETE loop that hit the saved-items rate limiter).
    if (primaryRemoveIds.isNotEmpty) {
      await primaryNotifier.bulkRemoveItems(primaryRemoveIds);
    }
    if (cascadeNotifier != null && cascadeRemoveIds.isNotEmpty) {
      await cascadeNotifier.bulkRemoveItems(cascadeRemoveIds);
    }

    // Adds still go one-by-one via the optimistic path.
    for (final src in primaryAddSrcs) {
      await _addEventToList(primaryListId, src);
    }
    if (cascadeListId != null) {
      for (final src in cascadeAddSrcs) {
        await _addEventToList(cascadeListId, src);
      }
    }

    if (_venueRowVisible && _addVenue && _venueDetail != null) {
      // Venue lands in the user's surface (primary).
      final completer = Completer<void>();
      ref
          .read(listsProvider.notifier)
          .addToListsOptimistic(
            [primaryListId],
            _venueToItemSuggestion(_venueDetail!),
            source: 'instagram_share_review',
            onSuccess: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (_, __, ___) {
              if (!completer.isCompleted) completer.complete();
            },
          );
      await completer.future;
    }

    // Force a server-truth refresh on every list we touched so any open
    // list-detail screen re-renders against the post-write state.
    await primaryNotifier.loadItemsQuietly();
    if (cascadeNotifier != null) {
      await cascadeNotifier.loadItemsQuietly();
    }

    ref
        .read(unifiedAnalyticsProvider)
        .trackInstagramShareReviewSave(
          keptCount: keptCount,
          totalCount: widget.share.eventIds.length,
          venueAdded: _venueRowVisible && _addVenue && _venueDetail != null,
          listId: primaryListId,
        );

    ref.read(instagramSharePollingProvider.notifier).dismiss();

    if (!mounted) return;
    navigator.pop();
    showSoko(
      ref,
      message: l10n.instagramShareReviewKept(keptCount),
      variant: SokoVariant.success,
      duration: const Duration(seconds: 3),
    );
  }

  /// Add an event to the given list via the optimistic add path. Used to
  /// re-add events that the user re-checks after a previous removal.
  /// Idempotent on the backend, per the share contract.
  Future<void> _addEventToList(String listId, UserListItem src) async {
    final completer = Completer<void>();
    ref
        .read(listsProvider.notifier)
        .addToListsOptimistic(
          [listId],
          _eventItemToSuggestion(src),
          source: 'instagram_share_review',
          onSuccess: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (_, __, ___) {
            if (!completer.isCompleted) completer.complete();
          },
        );
    await completer.future;
  }

  /// Build an [ItemSuggestion] from a `UserListItem` whose item_type is
  /// event. The fields come from the expanded `event` map already on the
  /// list-item row, so no extra fetch is needed.
  ItemSuggestion _eventItemToSuggestion(UserListItem item) {
    return ItemSuggestion(
      id: item.eventId ?? item.id,
      name: item.title ?? '',
      type: 'event',
      eventId: item.eventId,
      venueId: item.venueId,
      imageUrl: item.imageUrl,
      url: item.url,
      description: item.description,
      location: item.venueName,
      city: item.city,
      address: item.address,
      latitude: item.latitude,
      longitude: item.longitude,
      category: item.category,
      date: item.eventDate?.toIso8601String(),
      // PROD-3829: forward the facet through the share-review path too.
      primaryFacet: item.primaryFacet,
    );
  }

  ItemSuggestion _venueToItemSuggestion(VenueDetailResponse v) {
    return ItemSuggestion(
      id: v.id,
      name: v.name,
      imageUrl: v.imageUrl,
      type: 'place',
      venueId: v.id,
      description: v.descriptionLong ?? v.descriptionShort,
      latitude: v.latitude,
      longitude: v.longitude,
      address: v.address,
      city: v.city,
      rating: v.rating,
      ratingCount: v.ratingCount,
      tags: v.tags ?? const [],
      // PROD-3829: forward the facet through the share-review path too.
      primaryFacet: v.primaryFacet,
      googlePlaceId: v.googlePlaceId,
      googleMapsUrl: v.googleMapsUrl,
      website: v.website,
      phone: v.phone,
      openingHours: v.openingHours,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      // Drag handle hosted inside the pink header so the top edge of the
      // sheet is fully pink (matches PROD-1861 add-to-list chrome).
      showDragHandle: false,
      header: PickerPinkHeader(
        title: l10n.instagramShareReviewTitle,
        subtitle: l10n.instagramShareReviewSubtitle(
          widget.share.eventIds.length,
        ),
      ),
      body: _loadingItems
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: _displayItems.length + (_venueRowVisible ? 1 : 0),
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                if (index < _displayItems.length) {
                  return _buildEventPickerRow(_displayItems[index]);
                }
                return _buildVenuePickerRow(l10n);
              },
            ),
      footer: _ReviewFooter(
        cancelLabel: l10n.instagramShareReviewCancel,
        saveLabel: l10n.instagramShareReviewSave,
        saving: _saving,
        canSave: !_saving && !_loadingItems,
        onCancel: () {
          ref
              .read(unifiedAnalyticsProvider)
              .trackInstagramShareReviewCancel(
                eventCount: widget.share.eventIds.length,
                listId: _primaryListId,
              );
          Navigator.of(context).pop();
        },
        onSave: _onConfirm,
      ),
    );
  }

  /// Subtitle for an event row: deduped compact dates ("9 May" / "9 mai.")
  /// across all upcoming occurrences, locale-aware (no year, no time).
  /// Falls back to the legacy single `eventDate` when the embedded payload
  /// didn't ship the new `occurrences` array (older backends, or events
  /// with only past occurrences).
  String _occurrenceSubtitle(UserListItem item) {
    final fmt = DateFormat.MMMd(Localizations.localeOf(context).toString());
    final occs = item.occurrences;

    final seen = <String>{};
    final dates = <String>[];
    for (final o in occs) {
      final label = fmt.format(o.startAt.toLocal());
      if (seen.add(label)) dates.add(label);
    }
    if (dates.isEmpty) {
      final fallback = item.eventDate;
      if (fallback != null) {
        dates.add(fmt.format(fallback.toLocal()));
      }
    }
    return dates.join(' · ');
  }

  Widget _buildEventPickerRow(UserListItem item) {
    final eventId = item.eventId;
    final checked = eventId != null && _keepEventIds.contains(eventId);
    return PickerRow(
      isSelected: checked,
      item: PickerItem(
        id: eventId ?? item.id,
        title: item.title ?? '—',
        subtitle: _occurrenceSubtitle(item),
        imageUrl: item.imageUrl,
        defaultSelected: checked,
      ),
      onTap: _saving || eventId == null
          ? () {}
          : () {
              setState(() {
                if (_keepEventIds.contains(eventId)) {
                  _keepEventIds.remove(eventId);
                } else {
                  _keepEventIds.add(eventId);
                }
              });
            },
    );
  }

  Widget _buildVenuePickerRow(Lt l10n) {
    if (_venueLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final detail = _venueDetail;
    if (detail == null) return const SizedBox.shrink();

    final subtitle = (detail.address ?? detail.city ?? '').trim();
    return PickerRow(
      isSelected: _addVenue,
      item: PickerItem(
        id: 'venue:${detail.id}',
        title: detail.name,
        subtitle: subtitle.isEmpty
            ? l10n.instagramShareReviewVenueRowSubtitle
            : subtitle,
        imageUrl: detail.imageUrl,
        badgeLabel: l10n.instagramShareReviewVenueLabel,
        defaultSelected: _addVenue,
      ),
      onTap: _saving ? () {} : () => setState(() => _addVenue = !_addVenue),
    );
  }
}

/// Two-button sticky footer for the IG review sheet — Cancel + Save. Mirrors
/// the picker's footer chrome (sokoPaper bg, top shadow, sokoPink primary)
/// Sticky Cancel + Save footer using the DS `BtSqIco` button — mirrors the
/// `_Footer` in `instagram_share_sheet.dart`, just with a check icon for
/// the affirmative action (save the kept selection) instead of `send`.
class _ReviewFooter extends StatelessWidget {
  const _ReviewFooter({
    required this.cancelLabel,
    required this.saveLabel,
    required this.saving,
    required this.canSave,
    required this.onCancel,
    required this.onSave,
  });

  final String cancelLabel;
  final String saveLabel;
  final bool saving;
  final bool canSave;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.sokoPaper,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: LucideIcons.x,
              label: cancelLabel,
              variant: BtSqIcoVariant.normal,
              expand: true,
              onTap: saving ? () {} : onCancel,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Opacity(
              opacity: canSave ? 1.0 : 0.5,
              child: saving
                  ? _SavingButton(label: saveLabel)
                  : BtSqIco(
                      icon: LucideIcons.check,
                      label: saveLabel,
                      variant: BtSqIcoVariant.selected,
                      expand: true,
                      onTap: canSave ? onSave : () {},
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading variant of the save button — mirrors `_SubmittingButton` in
/// `instagram_share_sheet.dart`. Kept private; promote both to a shared
/// widget when the next caller appears (the TODO in
/// `instagram_share_sheet.dart` covers that follow-up).
class _SavingButton extends StatelessWidget {
  final String label;

  const _SavingButton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.sokoInk),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        ],
      ),
    );
  }
}
