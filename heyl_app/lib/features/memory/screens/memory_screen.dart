import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart'
    show unifiedAnalyticsProvider;
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/memory_twin_provider.dart';
import '../utils/memory_family_label.dart';
import '../utils/memory_hierarchy.dart';
import '../utils/memory_value_label.dart';
import '../../profile/providers/public_profile_providers.dart';
import '../../profile/widgets/memory_bio_section.dart';
import '../../profile/widgets/persona_card.dart';
import '../widgets/memory_confirm_sheet.dart';
import '../widgets/memory_error_state.dart';
import '../widgets/memory_overflow_menu.dart';
import '../widgets/memory_skeleton.dart';
import '../widgets/memory_tell_us_card.dart';
import '../widgets/parent_section.dart';
import '../../../providers/auth_provider.dart';

class MemoryScreen extends ConsumerStatefulWidget {
  /// Land with the "conta-nos sobre ti" composer already open — set by the
  /// profile shortcut (deep-linked via `?tellUs=1`).
  final bool openTellUs;
  const MemoryScreen({super.key, this.openTellUs = false});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  String? _expandedObservationId;
  final GlobalKey _moreKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Re-fetch on every entry so the page reflects activity (saves, views,
    // new zines) the moment it opens — no browser refresh needed. Silent: the
    // cached twin stays on screen and swaps when fresh data lands, so there's
    // no blank reload. On the very first mount the provider's own build()
    // already fetches, so we only top up when there's cached data to keep.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // PROD-3211: the Memory page had zero analytics.
      ref.read(unifiedAnalyticsProvider).trackMemoryOpen();
      if (ref.read(memoryTwinProvider).hasValue) {
        ref.read(memoryTwinProvider.notifier).silentRefresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final twinAsync = ref.watch(memoryTwinProvider);

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MemoryAppBar(
              moreKey: _moreKey,
              onMore: () => _openOverflow(twinAsync.valueOrNull),
            ),
            const _MemoryHeader(),
            Expanded(
              child: twinAsync.when(
                // Always render the parent list — even a brand-new user sees
                // every section up front, each empty one showing an inviting
                // hint (see ParentSection) rather than one generic blank state.
                data: (twin) => _buildList(twin),
                error: (_, __) => MemoryErrorState(
                  onRetry: () =>
                      ref.read(memoryTwinProvider.notifier).refresh(),
                ),
                loading: () => const MemorySkeleton(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _hasObservations(List<FamilyView> families) {
    for (final family in families) {
      for (final dim in family.dimensions) {
        if (dim.observations.isNotEmpty) return true;
      }
    }
    return false;
  }

  Widget _buildList(MemoryTwinResponse twin) {
    // Group families by parent. Any family the backend introduces and that
    // [parentForFamily] doesn't recognise lands under MemoryParent.practical.
    final familiesByParent = <MemoryParent, List<FamilyView>>{};
    for (final family in twin.families) {
      // PROD-2799 #1b: venue_types is heterogeneous — split its chips across
      // parent sections by each chip's category group (food→Tastes, culture→
      // Events, sport/active-outdoor→Sport & Outdoors, scenic-outdoor→Vibe,
      // utility→hidden) instead of dumping the whole family in one parent.
      if (family.family == 'venue_types') {
        splitVenueTypesByGroup(family).forEach((parent, fv) {
          familiesByParent.putIfAbsent(parent, () => <FamilyView>[]).add(fv);
        });
      } else if (family.family == eventSubCategoriesFamilyKey) {
        // PROD-3766: sport-* sub-categories render under Sport & Outdoors;
        // the rest group by category inside Events (see CompactFamilySection).
        splitEventSubCategoriesByParent(family).forEach((parent, fv) {
          familiesByParent.putIfAbsent(parent, () => <FamilyView>[]).add(fv);
        });
      } else {
        familiesByParent
            .putIfAbsent(parentForFamily(family.family), () => <FamilyView>[])
            .add(family);
      }
    }

    final sections = <Widget>[];
    var first = true;
    for (final parent in memoryParentRenderOrder) {
      // "Your collection" is no longer a section of its own — saved/followed
      // items now surface through the taste/vibe chips they produced (tap a
      // chip to see the venues/events/zines behind it). Skip the dedicated
      // parent so the page is one coherent list of interests.
      // "Your collection" never shows as its own section — its items surface
      // through the chips they produced.
      if (parent == MemoryParent.savedFollowed) continue;
      final families = familiesByParent[parent] ?? const <FamilyView>[];
      // Most parents show even when empty (an inviting hint nudges in-app
      // activity that fills them). Social is hidden until it has data: "who you
      // go out with" is chat-derived people, not venue/event activity, so an
      // empty invite would promise something this page can't do.
      if (parent == MemoryParent.social && !_hasObservations(families)) {
        continue;
      }
      if (!first) sections.add(const ChapterRule());
      first = false;
      sections.add(
        ParentSection(
          parent: parent,
          families: families,
          twin: twin,
          expandedObservationId: _expandedObservationId,
          onToggle: (id) {
            // PROD-3211: fire only on expand (not collapse) — browsing one's
            // own memory chips.
            if (_expandedObservationId != id) {
              final hit = _observationById(twin, id);
              if (hit != null) {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackMemoryRowTap(category: hit.$1, tag: hit.$2);
              }
            }
            setState(() {
              _expandedObservationId = _expandedObservationId == id ? null : id;
            });
          },
          onDeleteObservation: _confirmDeleteChip,
          onNudgeObservation: _nudgeChip,
          onClearCategory: _confirmClearCategory,
        ),
      );
    }

    // The bio is a nice-to-have; never let an unresolved auth graph crash the
    // whole page — fall back to rendering the sections without it.
    String? memoryBio;
    try {
      // LLM memory bio, shown under the persona card (same source as the
      // profile's memory section).
      final handle = ref.read(authStateProvider).user?.handle;
      if (handle != null && handle.isNotEmpty) {
        memoryBio = ref
            .watch(publicProfileProvider(handle))
            .valueOrNull
            ?.memoryBio;
      }
    } catch (_) {
      memoryBio = null;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
      children: [
        if (twin.personaTags.isNotEmpty) ...[
          const SizedBox(height: 8),
          PersonaCard(personaTags: twin.personaTags),
          const SizedBox(height: 8),
        ],
        // The LLM memory bio prose, right under the persona card.
        if (memoryBio != null && memoryBio.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: MemoryBioProse(text: memoryBio),
          ),
        ],
        MemoryTellUsCard(startExpanded: widget.openTellUs),
        // The template narrative (taste prose + activity count pills) used to
        // render here. Dropped — the LLM `MemoryBioProse` above already says
        // who you are, and the counts repeated what the sections below show.
        ...sections,
      ],
    );
  }

  Future<void> _openOverflow(MemoryTwinResponse? twin) async {
    final ctx = _moreKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset(box.size.width, box.size.height));
    final action = await showMemoryOverflowMenu(
      context,
      anchor: anchor,
      isEmpty: twin?.isEmpty ?? true,
    );
    if (action == null) return;
    switch (action) {
      case MemoryMenuAction.export:
        await _exportJson();
        break;
      case MemoryMenuAction.clearAll:
        await _confirmClearAll();
        break;
    }
  }

  /// Resolve an observation id to (family, chip value) for analytics —
  /// [ParentSection.onToggle] only surfaces the id.
  (String, String)? _observationById(MemoryTwinResponse twin, String id) {
    for (final family in twin.families) {
      for (final dim in family.dimensions) {
        for (final obs in dim.observations) {
          if (obs.id == id) return (family.family, obs.value);
        }
      }
    }
    return null;
  }

  Future<void> _confirmDeleteChip(
    DimensionView dimension,
    ObservationView obs,
  ) async {
    // Same canonical-token leak as the profile surface — quote what the chip
    // displays, not the raw value.
    final ok = await showMemoryDeleteItemSheet(
      context,
      quoted: humanizeMemoryValue(context, obs.value, family: dimension.family),
    );
    if (!ok) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackMemoryDelete(tag: obs.value, category: dimension.family);
    await ref.read(memoryTwinProvider.notifier).suppressChip(dimension, obs);
  }

  Future<void> _nudgeChip(
    DimensionView dimension,
    ObservationView obs,
    bool increase,
  ) async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackMemorySignalAdjust(
          tag: obs.value,
          category: dimension.family,
          direction: increase ? 'up' : 'down',
        );
    await ref
        .read(memoryTwinProvider.notifier)
        .nudgeChip(dimension, obs, increase: increase);
  }

  Future<void> _confirmClearCategory(FamilyView family) async {
    final familyLabel = memoryFamilyLabel(context, family.family);
    final ok = await showMemoryDeleteCategorySheet(
      context,
      family: familyLabel,
    );
    if (!ok) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackMemoryCategoryClear(category: family.family);
    await ref.read(memoryTwinProvider.notifier).deleteFamily(family.family);
  }

  Future<void> _confirmClearAll() async {
    final ok = await showMemoryClearAllSheet(context);
    if (!ok) return;
    await ref.read(memoryTwinProvider.notifier).clearAll();
  }

  Future<void> _exportJson() async {
    final bytes = await ref.read(memoryTwinProvider.notifier).exportJson();
    if (!mounted) return;
    final size = Uint8List.fromList(bytes).lengthInBytes;
    final l10n = Lt.of(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.memoryExportSnackbar(size))));
  }
}

class _MemoryAppBar extends StatelessWidget {
  final GlobalKey moreKey;
  final VoidCallback onMore;
  const _MemoryAppBar({required this.moreKey, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(LucideIcons.arrow_left, color: AppColors.sokoInk),
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          ),
          Expanded(
            child: Text(
              // Admin-only surface — tag the title like the menu's `[Admin]`
              // Memory entry (menu_screen.dart).
              '[Admin] ${l10n.memoryTitle}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.36,
              ),
            ),
          ),
          IconButton(
            key: moreKey,
            icon: const Icon(
              LucideIcons.ellipsis_vertical,
              color: AppColors.sokoInk,
            ),
            onPressed: onMore,
          ),
        ],
      ),
    );
  }
}

class _MemoryHeader extends StatelessWidget {
  const _MemoryHeader();

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 36,
                fontWeight: FontWeight.w300,
                height: 0.94,
                letterSpacing: -1.4,
                fontFamily: 'UnJamoBatang',
              ),
              children: [
                TextSpan(text: '${l10n.memoryDisplayLine1}\n'),
                TextSpan(
                  text: l10n.memoryDisplayLine2,
                  style: const TextStyle(
                    color: AppColors.sokoShade2,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.memorySubhead,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.35,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}
