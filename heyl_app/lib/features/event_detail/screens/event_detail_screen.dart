import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/navigation/sibling_prefetch.dart';
import '../../../shared/navigation/sibling_swipe_nav.dart';
import '../../discovery/widgets/shell_sliver_page.dart';
import '../../lists/utils/zine_item_color.dart';
import '../../share/utils/share_deep_link.dart';
import '../../share/widgets/soko_share_sheet.dart';
import '../../../data/models/entity_ref.dart';
import '../../../providers/detail_seed_provider.dart';
import '../providers/event_detail_provider.dart';
import '../utils/event_share.dart';
import '../widgets/event_detail_body.dart';

/// Full-screen event detail page (PROD-1671). Replaces the event branch of
/// the legacy item detail sheet (retired in PROD-1672).
///
/// Mounts inside [DiscoveryShell] (5-icon Discovery bottom nav). Two URL
/// forms are routed here:
///   - `/events/:eventId`                       — standalone
///   - `/lists/:listId/events/:eventId`         — in-list (back -> list)
///
/// **Body composition** lives on [EventDetailBody] — public widget so the
/// future list-embed wrapper (planned for the list-redesign work) can
/// reuse the same section column without duplication. This screen handles
/// only the full-screen chrome: provider watching, the
/// loading/loaded/error switch, and the
/// `ConstrainedBox(minHeight: viewportHeight)` that keeps short / loading
/// / error states from collapsing. The `view_item` analytics live on
/// [EventDetailBody] (so every host fires it), not here.
///
/// **Full-bleed background paint** (so the centred 480-px column doesn't
/// leak the cream Scaffold bg through on desktop) is owned by
/// [DiscoveryShell], which derives the colour from the current route. The
/// inner [ColoredBox] below keeps the body self-sufficient for the planned
/// embed mode.
///
/// **Layout note (mirrors `VenueDetailScreen`):** [DiscoveryShell] already
/// wraps the page in a single outer `SingleChildScrollView`, so the screen
/// tree below MUST be non-scrolling — a [Column], never a [ListView].
///
/// See `docs/designs/venue-event-details-redesign.md` and
/// `docs/features/event-detail.md` for the full spec.
class EventDetailScreen extends ConsumerStatefulWidget {
  final String eventId;
  final String? listId;

  /// Optional sibling-navigation context (set when the user opened this
  /// detail from a multi-item source — a chat message's card array or a
  /// saved list). Enables horizontal-swipe prev/next via [SiblingSwipeNav].
  final DetailSiblings? siblings;

  /// PROD-3319 — non-null when the route carried a recognised `?share=`
  /// param (share-nudge push deep link). Auto-presents the share sheet
  /// once the event loads; see [ShareDeepLinkAutoPresent].
  final ShareDeepLinkAction? autoShareAction;

  const EventDetailScreen({
    super.key,
    required this.eventId,
    this.listId,
    this.siblings,
    this.autoShareAction,
  });

  @override
  ConsumerState<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends ConsumerState<EventDetailScreen>
    with ShareDeepLinkAutoPresent<EventDetailScreen> {
  @override
  ShareDeepLinkAction? get autoShareAction => widget.autoShareAction;

  @override
  Widget build(BuildContext context) {
    final key = EventDetailKey(eventId: widget.eventId, listId: widget.listId);
    final asyncSnapshot = ref.watch(eventDetailProvider(key));
    final viewportHeight = MediaQuery.of(context).size.height;

    // PROD-3319: mirrors the body's `_ShareIconButton` tap exactly
    // (`event_detail_body.dart`), plus the `deep_link` entry point.
    maybeAutoPresentShare(
      ready: asyncSnapshot.hasValue,
      present: () {
        final snapshot = ref.read(eventDetailProvider(key)).valueOrNull;
        if (snapshot == null) return;
        showSokoShareSheet(
          context: context,
          ref: ref,
          // PROD-3952 — unconditionally `event` now. The `daily-drop`
          // attribution moved to the drop page's own share button.
          shareContext: 'event',
          entityId: snapshot.event.id,
          shareUrl: buildEventShareUrl(
            eventIdentifier: snapshot.event.id,
            listIdentifier: snapshot.effectiveListId,
          ),
          analyticsEntryPoint: shareDeepLinkEntryPoint,
        );
      },
    );

    final body = asyncSnapshot.when(
      data: (snapshot) =>
          EventDetailBody(snapshot: _withSeedBlurb(snapshot, key)),
      loading: () => _buildLoading(context, key),
      error: (err, st) => _buildError(context, err),
    );

    // PROD-4160-followup — the whole page (this ColoredBox + the shell's
    // full-bleed Scaffold bg + PinnedPageChrome) is the entity's image-derived
    // pastel, the same colour the zine/library use, replacing the fixed
    // Soko/Green. Derived from the loaded hero image (falls back to the
    // tapped-item seed's image, then an id-keyed pastel on a cold first frame)
    // and published to [standaloneDetailBgProvider] so the shell + chrome match.
    final loaded = asyncSnapshot.valueOrNull;
    final seedImageUrl = ref
        .detailSeed(EntityKind.event, key.eventId)
        ?.imageUrl;
    final bg = standaloneDetailBgColor(
      ref,
      key.eventId,
      imageUrl: loaded?.event.imageUrl ?? seedImageUrl,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(standaloneDetailBgProvider.notifier);
      if (notifier.state != bg) notifier.state = bg;
    });

    // PROD-1977: page owns its scrollable via [ShellSliverHost].
    return ColoredBox(
      // Full-bleed page background BEHIND the whole scroll view. The
      // chrome-reserved top gap is a transparent CustomScrollView region that
      // otherwise reveals the shell Scaffold bg — which lags for a frame or two
      // during the push transition (still the previous route's paper) and
      // flashes a white row across the top. Painting bg here makes the detail
      // self-sufficient. See docs/learnings/detail-page-shell-bg-paint.md.
      color: bg,
      child: ShellSliverHost(
        slivers: [
          SliverToBoxAdapter(
            child: PageContent(
              child: SiblingSwipeNav(
                siblings: widget.siblings,
                child: Stack(
                  children: [
                    ColoredBox(
                      color: bg,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: viewportHeight),
                        child: body,
                      ),
                    ),
                    // Invisible; warms next/prev sibling provider caches so
                    // swipe doesn't flash a loading state.
                    SiblingPrefetch(siblings: widget.siblings),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Keep the tapped-item seed's `description_short` blurb once the network
  /// detail hydrates but comes back without one — `EventDetailOut` often nulls
  /// it while the feed card carries it, so without this the blurb painted in
  /// the seed shell would flash then vanish. Only backfills when the seed has a
  /// value and the hydrated detail doesn't.
  EventDetailSnapshot _withSeedBlurb(
    EventDetailSnapshot snapshot,
    EventDetailKey key,
  ) {
    final hydrated = snapshot.event.descriptionShort?.trim() ?? '';
    if (hydrated.isNotEmpty) return snapshot;
    final seedShort = ref
        .detailSeed(EntityKind.event, key.eventId)
        ?.descriptionShort
        ?.trim();
    if (seedShort == null || seedShort.isEmpty) return snapshot;
    return EventDetailSnapshot(
      event: snapshot.event.copyWith(descriptionShort: seedShort),
      occurrences: snapshot.occurrences,
      parentList: snapshot.parentList,
      effectiveListId: snapshot.effectiveListId,
    );
  }

  Widget _buildLoading(BuildContext context, EventDetailKey key) {
    // PROD-4XXX: if a tapped-item seed exists, paint the shell (hero + title +
    // chips) from it while the full event hydrates, instead of a spinner.
    final seed = ref.detailSeed(EntityKind.event, key.eventId);
    if (seed != null) {
      return EventDetailBody(
        snapshot: EventDetailSnapshot(
          event: seed.toEventDetail(),
          effectiveListId: key.listId,
          // Seed shell: occurrences aren't known yet, so the action row renders
          // the reminder bell disabled (reserving its slot) rather than omitting
          // it and popping it in when the network detail lands.
          isHydrating: true,
        ),
      );
    }
    // Back arrow comes from `DiscoveryShell.PinnedPageChrome`.
    return const Padding(
      padding: EdgeInsets.fromLTRB(15, 80, 15, 0),
      child: Center(child: CircularProgressIndicator(color: AppColors.sokoInk)),
    );
  }

  Widget _buildError(BuildContext context, Object err) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 80, 15, 0),
      child: Column(
        children: [
          Center(
            child: Text(
              l10n.eventDetailErrorLoading,
              style: const TextStyle(color: AppColors.sokoInk, fontSize: 16),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: Text(
                err.toString(),
                style: TextStyle(
                  color: AppColors.sokoInk.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
