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
import '../providers/venue_detail_provider.dart';
import '../utils/venue_share.dart';
import '../widgets/venue_detail_body.dart';

/// Full-screen venue detail page. Replaces the place branch of
/// the legacy item detail sheet (retired in PROD-1672).
///
/// Mounts inside [DiscoveryShell] (5-icon Discovery bottom nav). Two URL
/// forms are routed here:
///   - `/venues/:venueId`                       — standalone
///   - `/lists/:listId/venues/:venueId`         — in-list (back -> list)
///
/// **Body composition** lives on [VenueDetailBody] — public widget so the
/// future list-embed wrapper (planned for the list-redesign work) can
/// reuse the same section column without duplication. This screen handles
/// only the full-screen chrome: provider watching, the
/// loading/loaded/error switch, and the
/// `ConstrainedBox(minHeight: viewportHeight)` that keeps short / loading
/// / error states from collapsing. The `view_item` analytics live on
/// [VenueDetailBody] (so every host fires it), not here.
///
/// **Full-bleed background paint** (so the centred 480-px column doesn't
/// leak the cream Scaffold bg through on desktop) is owned by
/// [DiscoveryShell], which derives the colour from the current route. The
/// inner [ColoredBox] below keeps the body self-sufficient for the planned
/// embed mode.
///
/// **Layout note:** [DiscoveryShell] already wraps the page in a single
/// outer `SingleChildScrollView` (so wheel events can be captured anywhere
/// in the viewport on desktop, and there is exactly one vertical
/// scrollable in the page tree). The screen tree below MUST therefore be
/// non-scrolling — a [Column], never a [ListView]. We mirror
/// [DiscoveryScreen]'s pattern.
///
/// See `docs/designs/venue-event-details-redesign.md` and
/// `docs/features/venue-detail.md` for the full spec.
class VenueDetailScreen extends ConsumerStatefulWidget {
  final String venueId;
  final String? listId;

  /// Optional sibling-navigation context (set when the user opened this
  /// detail from a multi-item source — a chat message's card array or a
  /// saved list). Enables horizontal-swipe prev/next via [SiblingSwipeNav].
  final DetailSiblings? siblings;

  /// PROD-3319 — non-null when the route carried a recognised `?share=`
  /// param (share-nudge push deep link). Auto-presents the share sheet
  /// once the venue loads; see [ShareDeepLinkAutoPresent].
  final ShareDeepLinkAction? autoShareAction;

  const VenueDetailScreen({
    super.key,
    required this.venueId,
    this.listId,
    this.siblings,
    this.autoShareAction,
  });

  @override
  ConsumerState<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

class _VenueDetailScreenState extends ConsumerState<VenueDetailScreen>
    with ShareDeepLinkAutoPresent<VenueDetailScreen> {
  @override
  ShareDeepLinkAction? get autoShareAction => widget.autoShareAction;

  @override
  Widget build(BuildContext context) {
    final key = VenueDetailKey(venueId: widget.venueId, listId: widget.listId);
    final asyncSnapshot = ref.watch(venueDetailProvider(key));
    final viewportHeight = MediaQuery.of(context).size.height;

    // PROD-3319: mirrors the body's `_ShareIconButton` tap exactly
    // (`venue_detail_body.dart`), plus the `deep_link` entry point.
    maybeAutoPresentShare(
      ready: asyncSnapshot.hasValue,
      present: () {
        final snapshot = ref.read(venueDetailProvider(key)).valueOrNull;
        if (snapshot == null) return;
        showSokoShareSheet(
          context: context,
          ref: ref,
          // PROD-3952 — unconditionally `venue` now. The `daily-drop`
          // attribution moved to the drop page's own share button.
          shareContext: 'venue',
          entityId: snapshot.venue.id,
          shareUrl: buildVenueShareUrl(
            venueIdentifier: snapshot.venue.id,
            listIdentifier: snapshot.effectiveListId,
          ),
          analyticsEntryPoint: shareDeepLinkEntryPoint,
        );
      },
    );

    final body = asyncSnapshot.when(
      data: (snapshot) => VenueDetailBody(snapshot: snapshot),
      loading: () => _buildLoading(context, key),
      error: (err, st) => _buildError(context, err),
    );

    // PROD-4160-followup — the whole page (this ColoredBox + the shell's
    // full-bleed Scaffold bg + PinnedPageChrome) is the entity's image-derived
    // pastel, replacing the fixed Soko/Blue. Mirrors EventDetailScreen: derive
    // from the loaded image (falls back to the tapped-item seed's image, then an
    // id-keyed pastel) and publish so shell + chrome match.
    final loaded = asyncSnapshot.valueOrNull;
    final seedImageUrl = ref
        .detailSeed(EntityKind.venue, key.venueId)
        ?.imageUrl;
    final bg = standaloneDetailBgColor(
      ref,
      key.venueId,
      imageUrl: loaded?.venue.imageUrl ?? seedImageUrl,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(standaloneDetailBgProvider.notifier);
      if (notifier.state != bg) notifier.state = bg;
    });

    // PROD-1977: page owns its scrollable via [ShellSliverHost]; the
    // shell-level [PinnedPageChrome] still renders over the top via the
    // Stack in DiscoveryShell. Inner ColoredBox + minHeight keep short
    // loading/error states filling the viewport without leaking the
    // Scaffold bg.
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

  Widget _buildLoading(BuildContext context, VenueDetailKey key) {
    // PROD-4XXX: if a tapped-item seed exists, paint the shell (hero + title +
    // chips) from it while the full venue hydrates, instead of a spinner.
    final seed = ref.detailSeed(EntityKind.venue, key.venueId);
    if (seed != null) {
      return VenueDetailBody(
        snapshot: VenueDetailSnapshot(
          venue: seed.toVenueDetail(),
          effectiveListId: key.listId,
        ),
      );
    }
    // Back arrow comes from `DiscoveryShell.PinnedPageChrome`; loading
    // state is just the spinner aligned with the body's normal gutter.
    return const Padding(
      padding: EdgeInsets.fromLTRB(15, 80, 15, 0),
      child: Center(child: CircularProgressIndicator(color: AppColors.sokoInk)),
    );
  }

  Widget _buildError(BuildContext context, Object err) {
    // Back arrow comes from `DiscoveryShell.PinnedPageChrome`.
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 80, 15, 0),
      child: Column(
        children: [
          Center(
            child: Text(
              l10n.venueDetailErrorLoading,
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
