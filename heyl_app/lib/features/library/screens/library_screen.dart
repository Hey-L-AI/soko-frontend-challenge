import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/event_time_formatter.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../core/utils/month_abbr.dart';
import '../../../data/models/library_feed.dart';
import '../../../data/models/user_list.dart' show ListVisibility;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/detail_seed_provider.dart';
import '../../../providers/saved_provider.dart';
import '../../lists/utils/zine_item_color.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/hero_image_warmup.dart';
import '../../../shared/widgets/search/unified_search_overlay.dart';
import '../../../shared/widgets/soko_pinned_header.dart';
import '../../discovery/feed_v2/widgets/blocks/feed_bundle_row.dart';
import '../../discovery/widgets/shell_sliver_page.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../../lists/utils/zine_cover_seed.dart';
import '../../lists/widgets/visibility_menu_chip.dart';
import '../../profile/widgets/textured_avatar.dart';
import '../../lists/utils/list_calendar_map_helpers.dart';
import '../../lists/widgets/list_page_calendar_block.dart';
import '../models/library_filter.dart';
import '../providers/library_calendar_provider.dart';
import '../providers/library_filter_provider.dart';
import '../search/library_search_source.dart';
import '../widgets/library_end_actions.dart';
import '../widgets/library_filter_bar.dart';
import '../widgets/library_item_row.dart';
import '../widgets/library_row_entrance.dart';
import '../widgets/library_sort_bar.dart';
import '../widgets/library_zine_follower_proof.dart';
import '../widgets/library_zine_thumb.dart';

/// Reserve at the bottom of the scroll for the floating bottom nav. Mirrors
/// `ListsHubScreen._kBottomNavReserve`.
const double _kBottomNavReserve = 96.0;
const double _kHorizontalPagePadding = 16.0;

/// Biblioteca hub. `/yours` still serves [ListsHubScreen].
class LibraryScreen extends ConsumerStatefulWidget {
  /// Filter to land on, resolved from `/library?tag=`. Null → no opinion:
  /// the tab parked by the previous visit stands.
  final LibraryFilter? landingFilter;

  const LibraryScreen({super.key, this.landingFilter});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late final ScrollController _scroll;

  /// Minimum scroll delta before the restore offset is written again.
  /// Roughly a third of a row — fine enough to land in the right place,
  /// coarse enough to stay off the per-frame path.
  static const double _kScrollSaveThreshold = 24.0;

  double _lastSavedOffset = 0;

  @override
  void initState() {
    super.initState();
    // Land back where the user left off. The feed's rows are still in the
    // kept-alive provider, so the extent exists on the first layout pass.
    _lastSavedOffset = widget.landingFilter == null
        ? ref.read(libraryScrollOffsetProvider)
        : 0;
    _scroll = ScrollController(initialScrollOffset: _lastSavedOffset);
    _scroll.addListener(_onScroll);
    // Everything below writes provider state, so it waits for the frame.
    // Writing from `initState` runs inside the build phase, where Riverpod
    // may reject the write.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Search is per-visit: the box is closed on mount, so the query that
      // drives the feed must not outlive the previous visit. The feed
      // providers now watch it while kept alive, so nothing resets it for us.
      final hadSearch = ref
          .read(librarySearchDebouncedQueryProvider)
          .isNotEmpty;
      resetLibrarySearch(ref);
      // The calendar is per-visit too: landing back on /library always shows
      // the feed, never a calendar parked by the previous visit.
      ref.read(libraryCalendarOpenProvider.notifier).state = false;
      // An explicit `?tag=` (the profile counters) overrides the parked tab.
      // Without one the parked tab stands — that's the whole point of #1515.
      final landing = widget.landingFilter;
      if (landing != null) {
        ref.read(libraryTabProvider.notifier).state = landing;
        // The parked offset belongs to the tab we just overrode.
        ref.read(libraryScrollOffsetProvider.notifier).state = 0;
      }
      if (!ref.read(isAuthenticatedProvider)) return;
      // Kick Saved/Lists — they hydrate from disk and sit still; owner is not in toJson.
      ref.read(savedProvider.notifier).loadSaved();
      // Clearing a stale query rebuilt the feed notifier, and a fresh
      // notifier fetches page 1 on its own. Revalidating here as well would
      // just double the request.
      if (hadSearch) return;
      _revalidateVisibleFeed();
    });
  }

  /// Refresh the parked page on mount. The rule lives in
  /// [libraryMountRefreshMode] so it can be unit-tested on its own.
  void _revalidateVisibleFeed() {
    final provider = libraryFeedFor(ref.read(libraryTabProvider));
    final silent = libraryMountRefreshMode(ref.read(provider));
    if (silent == null) return;
    ref.read(provider.notifier).refresh(silent: silent);
  }

  void _onScroll() {
    if (!mounted) return;
    if (!_scroll.hasClients) return;
    // Coarse: the offset only exists to restore the page on the next mount,
    // so a per-frame write would notify listeners 60x/second for nothing.
    final offset = _scroll.offset;
    if ((offset - _lastSavedOffset).abs() >= _kScrollSaveThreshold) {
      _lastSavedOffset = offset;
      ref.read(libraryScrollOffsetProvider.notifier).state = offset;
    }
    if (!ref.read(isAuthenticatedProvider)) return;
    final pos = _scroll.position;
    // Same 800 px prefetch as Descobre a cidade (PROD-4169 / PROD-2466).
    if (pos.maxScrollExtent - pos.pixels > 800) return;
    ref.read(libraryFeedFor(ref.read(libraryTabProvider)).notifier).loadMore();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lt = Lt.of(context);
    // Unified-search: searching is a focused OVERLAY (dimmed background + pinned
    // input), not an in-page mode. The filter-bar search icon flips
    // `librarySearchOpenProvider`; this opens the overlay and clears the flag
    // when it closes.
    ref.listen<bool>(librarySearchOpenProvider, (prev, next) async {
      if (next && !(prev ?? false)) {
        await openUnifiedSearchOverlay(
          context,
          hintText: lt.librarySearchHint,
          heroTag: kLibrarySearchHeroTag,
          // Scope search to the user's library — but to ALL of it: the
          // overlay's own category chips are the only scope control here, the
          // same as on the feed and in onboarding. The filter bar underneath is
          // neither applied to the results nor changed by them.
          source: const LibraryUnifiedSearchSource(),
          // Tapping a result closes the search overlay and opens the detail with
          // the same pastel-primed transition the list rows use. `payload` is
          // the LibraryFeedItem the source attached to the row.
          onOpen: (row) {
            final item = row.payload;
            if (item is! LibraryFeedItem) return false;
            Navigator.of(context, rootNavigator: true).maybePop();
            openLibraryFeedItem(context, ref, item);
            return true;
          },
        );
        if (!context.mounted) return;
        resetLibrarySearch(ref);
        ref.read(librarySearchOpenProvider.notifier).state = false;
      }
    });
    // Figma `7660:30303` (Soko_Library): calendar button leading, title
    // centred, + trailing. The calendar toggles the body between the feed
    // and the whole-library calendar; the glyph flips to a list so the way
    // back reads as an action rather than a dead button.
    final calendarOpen = ref.watch(libraryCalendarOpenProvider);
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kHorizontalPagePadding),
      child: SokoPinnedHeader(
        leading: SokoHeaderSlot.icon(
          icon: calendarOpen ? LucideIcons.list : LucideIcons.calendar,
          semanticLabel: calendarOpen
              ? lt.libraryCalendarCloseSemantic
              : lt.libraryCalendarSemantic,
          onTap: () {
            // Stale-while-revalidate, same contract as the parked feed:
            // reopening paints the parked set instantly and refetches
            // behind it (`when`'s skipLoadingOnRefresh keeps the data
            // branch up). First open has nothing parked → normal load.
            if (!calendarOpen &&
                ref.read(libraryCalendarItemsProvider).hasValue) {
              ref.invalidate(libraryCalendarItemsProvider);
            }
            ref.read(libraryCalendarOpenProvider.notifier).state =
                !calendarOpen;
          },
        ),
        centre: SokoHeaderSlot.titleLarge(lt.libraryTitle),
        trailing: SokoHeaderSlot.icon(
          icon: LucideIcons.plus,
          semanticLabel: lt.libraryCreateSemantic,
          onTap: () => context.push(AppRoutes.discoveryListCreate),
        ),
      ),
    );

    return ShellSliverHost(
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: PageContent(
            child: SafeArea(
              bottom: false,
              // **The page margin is applied per block, not to the page.**
              // The filter row has to reach the full content width or its
              // chips are visible-but-dead wherever they scroll into the
              // gutter: the escape trick `SearchCategoryTagRow` uses paints
              // outside the parent's box, and hit testing stops at the first
              // ancestor whose `size` excludes the point. So the row is
              // mounted unpadded and carries the margin itself, and every
              // other block is padded on its own.
              child: Padding(
                padding: const EdgeInsets.only(
                  top: 27,
                  bottom: _kBottomNavReserve,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: 30),
                    // Calendar mode replaces the whole feed apparatus —
                    // filters, sort and rows — with the one calendar over
                    // everything saved. `ListCalendarView` carries its own
                    // 16 px margins, so it mounts unpadded like the filter
                    // bar.
                    if (calendarOpen)
                      const _LibraryCalendarBody()
                    else ...[
                      const LibraryFilterBar(margin: _kHorizontalPagePadding),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _kHorizontalPagePadding,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: const [
                            LibrarySortBar(),
                            SizedBox(height: 30),
                            _LibraryBody(),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The whole library as a calendar — every saved event across owned and
/// followed lists, rendered by the same [ListPageCalendarBlock] the zine
/// detail mounts, month auto-picked the same way (closest events to today).
class _LibraryCalendarBody extends ConsumerWidget {
  const _LibraryCalendarBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(libraryCalendarItemsProvider);
    return items.when(
      // Fill the viewport below the header so the spinner sits at the
      // centre of the page rather than tucked up under the title. 320 ≈
      // top padding + safe area + header + gaps + bottom-nav reserve.
      loading: () => SizedBox(
        height: (MediaQuery.sizeOf(context).height - 320).clamp(
          200.0,
          double.infinity,
        ),
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => _LibraryErrorBlock(
        onRetry: () => ref.invalidate(libraryCalendarItemsProvider),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 40,
              horizontal: _kHorizontalPagePadding,
            ),
            child: Center(
              child: Text(
                Lt.of(context).libraryCalendarEmpty,
                textAlign: TextAlign.center,
                style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
              ),
            ),
          );
        }
        final now = DateTime.now();
        final month =
            autoPickMonthFromItems(items) ?? DateTime(now.year, now.month, 1);
        return ListPageCalendarBlock(items: items, currentMonth: month);
      },
    );
  }
}

class _LibraryBody extends ConsumerWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _ServerFeedBody(filter: ref.watch(libraryTabProvider));
  }
}

class _ServerFeedBody extends ConsumerWidget {
  const _ServerFeedBody({required this.filter});

  /// The active tab. `category == null` is the merged landing feed.
  final LibraryFilter filter;

  LibraryFeedItemType? get type =>
      filter.category == null ? null : libraryFeedTypeFor(filter.category!);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (type == LibraryFeedItemType.event &&
        filter.subFilter == LibrarySubFilter.data &&
        filter.selectedDate == null) {
      return _LibraryRows(filter: filter, rows: const []);
    }
    // Painting this filter IS the "recently used" signal for the LRU bound.
    // A parked page the user returns to does not rebuild its provider, so
    // without this the eviction order would be build order — which drops the
    // fixed tabs first as soon as someone browses a run of dates.
    if (filter.category != null) {
      ref.read(parkedLibraryPagesProvider).touch(filter);
    }
    final feed = ref.watch(libraryFeedFor(filter));

    if (feed.loading && feed.items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (feed.error != null && feed.items.isEmpty) {
      return _LibraryErrorBlock(
        onRetry: () => ref.read(libraryFeedFor(filter).notifier).refresh(),
      );
    }

    if (type == LibraryFeedItemType.event || type == null) {
      final days = <DateTime>{
        for (final item in feed.items)
          if (item is LibraryFeedEvent && item.startAt != null)
            calendarDay(item.startAt!),
      };
      final current = ref.read(libraryEventHighlightDaysProvider);
      if (days.length != current.length || !days.containsAll(current)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          ref.read(libraryEventHighlightDaysProvider.notifier).state = days;
        });
      }
    }

    final rows = [
      for (var i = 0; i < feed.items.length; i++)
        _rowFor(context, ref, feed.items[i], index: i),
    ];
    return _LibraryRows(
      filter: filter,
      rows: rows,
      hasMore: feed.hasMore,
      loadingMore: feed.loadingMore,
      loadMoreError: feed.loadMoreError,
      onLoadMore: () => ref.read(libraryFeedFor(filter).notifier).loadMore(),
      onRetryLoadMore: () =>
          ref.read(libraryFeedFor(filter).notifier).loadMore(),
    );
  }

  Widget _rowFor(
    BuildContext context,
    WidgetRef ref,
    LibraryFeedItem item, {
    required int index,
  }) {
    return switch (item) {
      LibraryFeedZine() => _zineRow(context, ref, item, index: index),
      LibraryFeedEvent() => _eventRow(context, ref, item),
      LibraryFeedPlace() => _placeRow(context, ref, item),
      LibraryFeedPerson() => _personRow(context, ref, item),
    };
  }

  Widget _zineRow(
    BuildContext context,
    WidgetRef ref,
    LibraryFeedZine item, {
    required int index,
  }) {
    final lt = Lt.of(context);
    final curator = item.owner.fullName ?? item.owner.handle;
    final recipe = libraryZineCoverRecipe(item);
    final vis = libraryZineVisibility(item.visibility);

    // Visibility owns its own row under the curator/count line: a private zine
    // says "private"; a public one answers "who follows it", falling back to
    // "public" when nobody does. Rendered as a chip line, or as the follower
    // faces widget when the feed shipped a preview.
    final proof = (item.followerPreview?.isNotEmpty ?? false)
        ? LibraryZineFollowerProof(
            listId: item.id,
            listName: item.name,
            preview: item.followerPreview!,
            followerCount: item.followerCount,
          )
        : null;
    final followerCount = item.followerCount ?? 0;
    // Null only when the feed sent an unknown visibility — then the row is
    // dropped rather than guessed at.
    final visChipFor = vis == null
        ? null
        : MetaChip(
            visibilityLabel(lt, vis),
            icon: visibilityIcon(vis),
            tight: true,
          );

    MetaChip? statusChip;
    Widget? statusLine;
    if (vis == ListVisibility.private || vis == ListVisibility.followers) {
      statusChip = visChipFor;
    } else if (proof != null) {
      statusLine = proof;
    } else if (followerCount > 0) {
      statusChip = MetaChip(
        lt.libraryFollowerCount(followerCount),
        icon: LucideIcons.bookmark,
        tight: true,
      );
    } else {
      statusChip = visChipFor;
    }

    return LibraryItemRow(
      title: item.name,
      thumbnail: LibraryZineThumb(
        listId: item.id,
        name: item.name,
        coverRecipe: recipe,
      ),
      showPin: item.pinState != LibraryPinState.notPinned,
      metaLines: [
        [
          if (curator.isNotEmpty)
            MetaChip(
              lt.libraryCurator(curator),
              avatarUrl: item.owner.avatarUrl,
            ),
          MetaChip(
            lt.libraryItemCount(item.itemCount),
            icon: LucideIcons.book_open,
            tight: true,
          ),
        ],
        if (statusChip != null) [statusChip],
      ],
      trailingLine: statusLine,
      onTap: () {
        ref.cacheZineCoverSeed(
          item.id,
          ZineCoverSeed(recipe: recipe, title: item.name),
        );
        // Warm the cover photo so the opened zine paints its real cover on
        // frame 1 instead of the solid-colour fallback.
        warmHeroImage(context, recipe.photoUrl);
        _pushLibraryRoute(context, ref, '/lists/${item.id}');
      },
    );
  }

  Widget _eventRow(BuildContext context, WidgetRef ref, LibraryFeedEvent item) {
    final lt = Lt.of(context);
    final meta = <List<MetaChip>>[];
    final first = <MetaChip>[];
    if (item.startAt != null) {
      first.add(
        MetaChip(
          _libraryFeedEventWhen(
            context,
            start: item.startAt!,
            end: item.endAt,
            timeKnown: item.timeKnown,
          ),
          icon: LucideIcons.calendar,
        ),
      );
    }
    if (item.category != null && item.category!.isNotEmpty) {
      first.add(MetaChip(item.category!, icon: LucideIcons.arrow_up_right));
    }
    if (first.isNotEmpty) meta.add(first);
    if (item.venueName != null && item.venueName!.isNotEmpty) {
      meta.add([MetaChip(item.venueName!, icon: LucideIcons.map_pin)]);
    }
    return LibraryItemRow(
      title: item.title.isEmpty ? lt.libraryUntitled : item.title,
      thumbnail: FeedBundleRow.eventPhotoThumb(
        item.imageUrl,
        paperGrain: false,
      ),
      showPin: item.pinState != LibraryPinState.notPinned,
      metaLines: meta,
      onTap: () => _openLibraryEntity(
        context,
        ref,
        route: '/events/${item.id}',
        entityId: item.id,
        seed: DetailSeed.fromLibraryEvent(item),
      ),
    );
  }

  Widget _placeRow(BuildContext context, WidgetRef ref, LibraryFeedPlace item) {
    final lt = Lt.of(context);
    final meta = <List<MetaChip>>[];
    if (item.category != null && item.category!.isNotEmpty) {
      meta.add([MetaChip(item.category!, icon: LucideIcons.arrow_up_right)]);
    }
    final where = item.address ?? item.city;
    if (where != null && where.isNotEmpty) {
      meta.add([MetaChip(where, icon: LucideIcons.map_pin)]);
    }
    return LibraryItemRow(
      title: item.name.isEmpty ? lt.libraryUntitled : item.name,
      thumbnail: FeedBundleRow.placePhotoThumb(
        item.imageUrl,
        paperGrain: false,
      ),
      showPin: item.pinState != LibraryPinState.notPinned,
      metaLines: meta,
      onTap: () => _openLibraryEntity(
        context,
        ref,
        route: '/venues/${item.id}',
        entityId: item.id,
        seed: DetailSeed.fromLibraryPlace(item),
      ),
    );
  }

  Widget _personRow(
    BuildContext context,
    WidgetRef ref,
    LibraryFeedPerson item,
  ) {
    final lt = Lt.of(context);
    final proof = item.socialProof;
    String? proofLabel;
    if (proof != null) {
      proofLabel = switch (proof.kind) {
        LibrarySocialProofKind.followedBy =>
          (proof.actor?.fullName ?? '').isEmpty
              ? null
              : lt.librarySocialFollowedBy(proof.actor!.fullName!),
        LibrarySocialProofKind.mutualFollows =>
          proof.count == null ? null : lt.librarySocialMutual(proof.count!),
      };
    }
    final handle = item.handle.replaceFirst(RegExp(r'^@'), '');
    return LibraryItemRow(
      title: item.displayName.isEmpty ? lt.libraryUntitled : item.displayName,
      thumbnail: TexturedAvatar(
        url: item.avatarUrl,
        name: item.displayName,
        colorSeed: item.id,
        width: kLibraryThumbWidth,
        height: kLibraryPersonRowHeight,
        initialFontScale: 0.34,
      ),
      height: kLibraryPersonRowHeight,
      metaLines: [
        [
          if (handle.isNotEmpty) MetaChip('@$handle'),
          if (proofLabel != null)
            MetaChip(
              proofLabel,
              avatarUrl: proof?.kind == LibrarySocialProofKind.followedBy
                  ? proof?.actor?.avatarUrl
                  : null,
            ),
        ],
      ],
      onTap: handle.isEmpty
          ? null
          : () => _pushLibraryRoute(context, ref, '/u/$handle'),
    );
  }
}

/// The zine cover recipe, in one place so the list thumbnail and the
/// detail-open priming (list + search) agree on the same cover.
ZineCoverRecipe libraryZineCoverRecipe(LibraryFeedZine item) {
  final fallbackPhoto = item.previewImages.isNotEmpty
      ? item.previewImages.first
      : null;
  return ZineCoverRecipe.fromFields(
    listId: item.id,
    coverType: item.coverType,
    coverColor: item.coverColor,
    coverTexture: item.coverTexture,
    coverTextColor: item.coverTextColor,
    coverItemId: null,
    legacyCoverImageUrl: item.coverImageUrl,
    fallbackItemImageUrl: fallbackPhoto,
    showTitle: item.coverShowTitle,
    showTexture: item.coverShowTexture,
    showLogo: item.coverShowLogo,
  );
}

/// Push [route] and, on return, silently refresh the parked library feed
/// (recency was stamped by the detail GET; there is no `POST .../open`).
void _pushLibraryRoute(BuildContext context, WidgetRef ref, String route) {
  context.push(route).then((_) {
    if (!context.mounted) return;
    ref
        .read(libraryFeedFor(ref.read(libraryTabProvider)).notifier)
        .refresh(silent: true);
  });
}

/// Open an event/venue detail with the shared-element morph + pastel background
/// primed (PROD-4160-followup): a synchronous on-brand pastel to
/// [standaloneDetailBgProvider] so the detail's shell paints the right colour on
/// frame 1, the seed cached so hero + title paint instantly, and the poster
/// warmed so the Hero flies the real photo on a cold cache.
void _openLibraryEntity(
  BuildContext context,
  WidgetRef ref, {
  required String route,
  required String entityId,
  required DetailSeed seed,
}) {
  ref.read(standaloneDetailBgProvider.notifier).state =
      cachedZineItemColor(ref, entityId) ?? zineItemFallbackColor(entityId);
  ref.cacheDetailSeed(seed);
  warmHeroImage(context, seed.imageUrl);
  _pushLibraryRoute(context, ref, route);
}

/// Open any library feed item's detail with the same priming the list rows use.
/// Reused by the search overlay's result taps (via `onOpen`), so a saved item
/// opened from search animates in exactly like one tapped in the list.
void openLibraryFeedItem(
  BuildContext context,
  WidgetRef ref,
  LibraryFeedItem item,
) {
  switch (item) {
    case LibraryFeedEvent e:
      _openLibraryEntity(
        context,
        ref,
        route: '/events/${e.id}',
        entityId: e.id,
        seed: DetailSeed.fromLibraryEvent(e),
      );
    case LibraryFeedPlace p:
      _openLibraryEntity(
        context,
        ref,
        route: '/venues/${p.id}',
        entityId: p.id,
        seed: DetailSeed.fromLibraryPlace(p),
      );
    case LibraryFeedZine z:
      final recipe = libraryZineCoverRecipe(z);
      ref.cacheZineCoverSeed(
        z.id,
        ZineCoverSeed(recipe: recipe, title: z.name),
      );
      warmHeroImage(context, recipe.photoUrl);
      _pushLibraryRoute(context, ref, '/lists/${z.id}');
    case LibraryFeedPerson u:
      final handle = u.handle.replaceFirst(RegExp(r'^@'), '');
      if (handle.isEmpty) return;
      _pushLibraryRoute(context, ref, '/u/$handle');
  }
}

class _LibraryRows extends ConsumerWidget {
  const _LibraryRows({
    required this.filter,
    required this.rows,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreError,
    this.onLoadMore,
    this.onRetryLoadMore,
  });

  final LibraryFilter filter;
  final List<Widget> rows;
  final bool hasMore;
  final bool loadingMore;
  final Object? loadMoreError;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetryLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(libraryViewProvider) == LibraryViewMode.grid;
    final list = grid
        ? LayoutBuilder(
            builder: (context, constraints) {
              const gap = kLibraryRowGap;
              final tileW = (constraints.maxWidth - gap) / 2;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    SizedBox(
                      width: tileW,
                      child: LibraryRowEntrance(
                        index: i,
                        generation: filter,
                        child: rows[i],
                      ),
                    ),
                ],
              );
            },
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: kLibraryRowGap),
                LibraryRowEntrance(
                  index: i,
                  generation: filter,
                  child: rows[i],
                ),
              ],
            ],
          );
    final showPager =
        onLoadMore != null && (hasMore || loadingMore || loadMoreError != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        list,
        if (showPager)
          _LibraryLoadMoreFooter(
            hasMore: hasMore,
            loadingMore: loadingMore,
            hasError: loadMoreError != null,
            onVisible: onLoadMore!,
            onRetry: onRetryLoadMore,
          ),
        // The "Importar do Instagram / Adicionar evento …" create rows are the
        // landing's add-affordances. Once a filter is applied the list is a
        // filtered result set, so they'd read as stray results — hide them.
        if (filter.isInitial) ...[
          if (rows.isNotEmpty) const SizedBox(height: kLibraryRowGap),
          LibraryEndActions(category: filter.category),
        ],
      ],
    );
  }
}

/// Keep-items pager, same shape as [SearchResultsView]'s footer (PROD-4169).
class _LibraryLoadMoreFooter extends StatelessWidget {
  const _LibraryLoadMoreFooter({
    required this.hasMore,
    required this.loadingMore,
    required this.hasError,
    required this.onVisible,
    this.onRetry,
  });

  final bool hasMore;
  final bool loadingMore;
  final bool hasError;
  final VoidCallback onVisible;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ink = AppColors.sokoInk;
    if (hasError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Clickable(
            onTap: onRetry,
            child: Text(
              Lt.of(context).discoveryShelfErrorRetry,
              textAlign: TextAlign.center,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                color: ink.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }
    return VisibilityDetector(
      key: const Key('library-load-more-sentinel'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction > 0 && hasMore && !loadingMore) {
          onVisible();
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ink.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryErrorBlock extends StatelessWidget {
  const _LibraryErrorBlock({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final lt = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Clickable(
          onTap: onRetry,
          child: Text(
            lt.discoveryShelfErrorRetry,
            textAlign: TextAlign.center,
            style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
          ),
        ),
      ),
    );
  }
}

String _libraryFeedEventWhen(
  BuildContext context, {
  required DateTime start,
  DateTime? end,
  required bool timeKnown,
}) {
  if (end != null) {
    final s = start.toLocal();
    final e = end.toLocal();
    if (s.year != e.year || s.month != e.month || s.day != e.day) {
      return _libraryDateRange(context, s, e);
    }
  }
  return _libraryEventWhen(context, start, timeKnown: timeKnown);
}

String _libraryDateRange(BuildContext context, DateTime start, DateTime end) {
  final locale = Localizations.localeOf(context).toString();
  final dayMonth = locale.startsWith('pt') || locale.startsWith('es');
  final sm = formatMonthAbbr(start, locale);
  final em = formatMonthAbbr(end, locale);
  if (start.month == end.month && start.year == end.year) {
    return dayMonth
        ? '${start.day} - ${end.day} $em'
        : '$sm ${start.day}–${end.day}';
  }
  final left = dayMonth ? '${start.day} $sm' : '$sm ${start.day}';
  final right = dayMonth ? '${end.day} $em' : '$em ${end.day}';
  return '$left - $right';
}

/// [formatEventWhen] maps past dates to "Today"; Passados needs an absolute date.
String _libraryEventWhen(
  BuildContext context,
  DateTime startsAt, {
  bool timeKnown = true,
}) {
  final locale = Localizations.localeOf(context).toString();
  final start = startsAt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final startDay = DateTime(start.year, start.month, start.day);

  if (!startDay.isBefore(today)) {
    return formatEventWhen(
      context: context,
      startsAt: start,
      timeKnown: timeKnown,
    );
  }

  final monthAbbr = formatMonthAbbr(start, locale);
  final isPt = locale.startsWith('pt');
  final day = isPt ? '${start.day} $monthAbbr' : '$monthAbbr ${start.day}';
  final dated = start.year == now.year ? day : '$day ${start.year}';
  if (!timeKnown) return dated;
  return '$dated, ${formatEventTime(start, locale)}';
}
