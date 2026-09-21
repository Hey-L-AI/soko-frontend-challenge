import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/navigation/sibling_prefetch.dart';
import '../../../shared/navigation/sibling_swipe_nav.dart';
import '../../discovery/widgets/shell_sliver_page.dart';
import '../../../data/models/entity_ref.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../event_detail/providers/event_detail_provider.dart';
import '../../event_detail/utils/event_share.dart';
import '../../event_detail/widgets/event_detail_body.dart';
import '../../share/utils/share_deep_link.dart';
import '../../share/widgets/soko_share_sheet.dart';
import '../../venue_detail/providers/venue_detail_provider.dart';
import '../../venue_detail/utils/venue_share.dart';
import '../../venue_detail/widgets/venue_detail_body.dart';
import '../providers/current_zine_page_provider.dart';
import '../providers/unified_list_provider.dart';
import '../utils/zine_hero_tags.dart';
import '../utils/zine_item_color.dart';

/// Identifies which kind of entity the in-list detail wraps.
enum ListInContextEntityKind { venue, event }

/// In-list detail screen — rendered when a user taps "Vê mais" on a zine
/// item page (or any item row in list view). Mounts:
///
/// 1. A card-bounded `ColoredBox` (Soko/Blue for venues, Soko/Lilac for
///    events) with rounded corners, painted strictly within the card's
///    bounds — the page bg stays Soko/Paper. This is the "three-layer
///    model" from `docs/designs/list-page-redesign.md` § 9.2 #25.
/// 2. The shared body widget ([VenueDetailBody] / [EventDetailBody]) in
///    `embedded: true` mode (PROD-1701), which strips top inset /
///    bottom-nav clearance / back-button row so the shell-level
///    `PinnedPageChrome` owns the chrome.
///
/// The chrome (back arrow + list name) is rendered by `DiscoveryShell`
/// based on the matched route — `/lists/<id>/(venues|events)/<id>` and
/// the parent `/lists/<id>` route share the same chrome content, so
/// pushing into / popping out of the in-list detail does not cause the
/// chrome to flicker (PROD-1738).
///
/// **§ 7.7 share-from-private-list edge case**: if the parent list 404s
/// (e.g. the share link points to a list the viewer can't see), we
/// gracefully redirect to the standalone detail route.
class ListInContextDetailScreen extends ConsumerStatefulWidget {
  final String listId;
  final String entityId;
  final ListInContextEntityKind kind;

  /// Optional sibling-navigation context — when the user opened this
  /// detail from a list tap, the array of list items rides along via
  /// go_router's `extra` and enables horizontal-swipe prev/next.
  final DetailSiblings? siblings;

  /// PROD-3319 — non-null when the route carried a recognised `?share=`
  /// param (share-nudge push deep link). Auto-presents the share sheet
  /// once the entity loads; see [ShareDeepLinkAutoPresent].
  final ShareDeepLinkAction? autoShareAction;

  const ListInContextDetailScreen({
    super.key,
    required this.listId,
    required this.entityId,
    required this.kind,
    this.siblings,
    this.autoShareAction,
  });

  @override
  ConsumerState<ListInContextDetailScreen> createState() =>
      _ListInContextDetailScreenState();
}

class _ListInContextDetailScreenState
    extends ConsumerState<ListInContextDetailScreen>
    with ShareDeepLinkAutoPresent<ListInContextDetailScreen> {
  bool _redirected = false;

  @override
  void initState() {
    super.initState();
    _publishSyncTarget();
  }

  @override
  void didUpdateWidget(covariant ListInContextDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sibling swipe (`context.replace`) may reuse this State with a new
    // entity — re-publish so the underlying zine tracks the swipe.
    if (oldWidget.entityId != widget.entityId) _publishSyncTarget();
  }

  /// PROD-4XXX — tell the underlying zine which item is on screen here, so it
  /// can jump its pager to match and a back-press lands on the same page.
  void _publishSyncTarget() {
    final listId = widget.listId;
    final entityId = widget.entityId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(zineDetailSyncTargetProvider(listId).notifier).state = entityId;
    });
  }

  @override
  ShareDeepLinkAction? get autoShareAction => widget.autoShareAction;

  VenueDetailKey get _venueKey =>
      VenueDetailKey(venueId: widget.entityId, listId: widget.listId);
  EventDetailKey get _eventKey =>
      EventDetailKey(eventId: widget.entityId, listId: widget.listId);

  /// PROD-3319: mirrors the embedded bodies' `_ShareIconButton` taps
  /// exactly, plus the `deep_link` entry point.
  void _presentShareSheet() {
    if (widget.kind == ListInContextEntityKind.venue) {
      final snapshot = ref.read(venueDetailProvider(_venueKey)).valueOrNull;
      if (snapshot == null) return;
      showSokoShareSheet(
        context: context,
        ref: ref,
        shareContext: 'venue',
        entityId: snapshot.venue.id,
        shareUrl: buildVenueShareUrl(
          venueIdentifier: snapshot.venue.id,
          listIdentifier: snapshot.effectiveListId,
        ),
        analyticsEntryPoint: shareDeepLinkEntryPoint,
      );
    } else {
      final snapshot = ref.read(eventDetailProvider(_eventKey)).valueOrNull;
      if (snapshot == null) return;
      showSokoShareSheet(
        context: context,
        ref: ref,
        shareContext: 'event',
        entityId: snapshot.event.id,
        shareUrl: buildEventShareUrl(
          eventIdentifier: snapshot.event.id,
          listIdentifier: snapshot.effectiveListId,
        ),
        analyticsEntryPoint: shareDeepLinkEntryPoint,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(unifiedListProvider(widget.listId));
    final viewportHeight = MediaQuery.of(context).size.height;

    // § 7.7: if the parent list isn't accessible, fall back to the
    // standalone detail route. A pending `?share=` marker rides along so
    // the standalone screen still auto-presents (PROD-3319).
    if (state.isNotFound && !_redirected) {
      _redirected = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final share = widget.autoShareAction;
        final marker = share != null ? '?share=${share.queryValue}' : '';
        final fallback = widget.kind == ListInContextEntityKind.venue
            ? '/venues/${widget.entityId}$marker'
            : '/events/${widget.entityId}$marker';
        context.go(fallback);
      });
      return const SizedBox.shrink();
    }

    // PROD-3319: `?share=` deep link → auto-present once the entity's
    // detail provider (the same family instance [_DetailBody] watches)
    // has data.
    final entityReady = widget.kind == ListInContextEntityKind.venue
        ? ref.watch(venueDetailProvider(_venueKey)).hasValue
        : ref.watch(eventDetailProvider(_eventKey)).hasValue;
    maybeAutoPresentShare(ready: entityReady, present: _presentShareSheet);

    // PROD-4160-followup — the in-list detail card no longer uses the fixed
    // Soko/Blue (venue) vs Soko/Green (event) split. It adopts the same
    // image-derived pastel the zine card uses, resolved from the SAME provider
    // + key (entity id + the tapped item's image, carried on the seed), so the
    // colour is identical at both ends of the Hero flight (no "pop" on land).
    // Falls back to the sync colour cache, then neutral Shade5, on frame 1.
    final entityKind = widget.kind == ListInContextEntityKind.venue
        ? EntityKind.venue
        : EntityKind.event;
    final seedImageUrl = ref.detailSeed(entityKind, widget.entityId)?.imageUrl;
    final cardColor =
        ref
            .watch(
              zineItemColorProvider(
                ZineItemColorKey(
                  itemId: widget.entityId,
                  imageUrl: seedImageUrl,
                ),
              ),
            )
            .valueOrNull ??
        cachedZineItemColor(ref, widget.entityId) ??
        AppColors.sokoShade5;

    // PROD-1977: page owns its scrollable via [ShellSliverHost].
    return ShellSliverHost(
      slivers: [
        SliverToBoxAdapter(
          child: PageContent(
            child: SiblingSwipeNav(
              siblings: widget.siblings,
              child: Stack(
                children: [
                  ColoredBox(
                    color: AppColors.sokoPaper,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: viewportHeight),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 15),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Stack(
                                children: [
                                  // PROD-4160-followup — the coloured card
                                  // region is a Hero so the zine card's colour
                                  // panel expands into it. It's a background
                                  // layer (Positioned.fill) so it doesn't wrap
                                  // — and thus doesn't nest with — the collage's
                                  // poster Hero living inside _DetailBody.
                                  Positioned.fill(
                                    child: Hero(
                                      tag: zineDetailColorHeroTag(
                                        widget.entityId,
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: ColoredBox(color: cardColor),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 15),
                                    child: _DetailBody(
                                      listId: widget.listId,
                                      entityId: widget.entityId,
                                      kind: widget.kind,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(
                            height: MediaQuery.of(context).padding.bottom + 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Invisible; warms next/prev sibling provider caches so swipe
                  // doesn't flash a loading state.
                  SiblingPrefetch(siblings: widget.siblings),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailBody extends ConsumerWidget {
  final String listId;
  final String entityId;
  final ListInContextEntityKind kind;

  const _DetailBody({
    required this.listId,
    required this.entityId,
    required this.kind,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);

    if (kind == ListInContextEntityKind.venue) {
      final asyncSnapshot = ref.watch(
        venueDetailProvider(VenueDetailKey(venueId: entityId, listId: listId)),
      );
      return asyncSnapshot.when(
        data: (snapshot) => VenueDetailBody(snapshot: snapshot, embedded: true),
        // PROD-4XXX: paint the shell from the tapped-item seed while the full
        // venue hydrates, instead of a full-page spinner.
        loading: () {
          final seed = ref.detailSeed(EntityKind.venue, entityId);
          if (seed != null) {
            return VenueDetailBody(
              snapshot: VenueDetailSnapshot(
                venue: seed.toVenueDetail(),
                effectiveListId: listId,
              ),
              embedded: true,
            );
          }
          return const _Loading();
        },
        error: (err, _) => _ErrorView(
          message: l10n.venueDetailErrorLoading,
          detail: err.toString(),
        ),
      );
    } else {
      final asyncSnapshot = ref.watch(
        eventDetailProvider(EventDetailKey(eventId: entityId, listId: listId)),
      );
      return asyncSnapshot.when(
        data: (snapshot) => EventDetailBody(snapshot: snapshot, embedded: true),
        // PROD-4XXX: paint the shell from the tapped-item seed while the full
        // event hydrates, instead of a full-page spinner.
        loading: () {
          final seed = ref.detailSeed(EntityKind.event, entityId);
          if (seed != null) {
            return EventDetailBody(
              snapshot: EventDetailSnapshot(
                event: seed.toEventDetail(),
                effectiveListId: listId,
                isHydrating: true,
              ),
              embedded: true,
            );
          }
          return const _Loading();
        },
        error: (err, _) => _ErrorView(
          message: l10n.venueDetailErrorLoading,
          detail: err.toString(),
        ),
      );
    }
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80),
      child: Center(child: CircularProgressIndicator(color: AppColors.sokoInk)),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final String detail;

  const _ErrorView({required this.message, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 16),
      child: Column(
        children: [
          Text(
            message,
            style: const TextStyle(color: AppColors.sokoInk, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: TextStyle(
              color: AppColors.sokoInk.withValues(alpha: 0.6),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
