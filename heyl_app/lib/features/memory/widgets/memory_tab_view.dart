import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart'
    show unifiedAnalyticsProvider;
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/memory_twin_provider.dart';
import '../../../shared/widgets/soko_brain_icon.dart';
import '../../profile/providers/public_profile_providers.dart';
import '../../profile/utils/profile_style.dart';
import '../../profile/widgets/memory_bio_section.dart';
import '../../profile/widgets/persona_flat_card.dart';
import '../utils/memory_hierarchy.dart';
import '../utils/memory_value_label.dart';
import 'memory_confirm_sheet.dart';
import 'memory_error_state.dart';
import 'memory_section.dart';
import 'memory_skeleton.dart';
import 'memory_tell_us_card.dart';

/// The "Memória" tab of your own profile — persona, the prose Soko wrote about
/// you, the free-text composer, and one collapsible section per memory parent
/// with its values as tunable bars.
///
/// Sliver-free: it is handed to a `TabBarView`, so it owns its own scroll.
class MemoryTabView extends ConsumerStatefulWidget {
  /// Land with the free-text composer already open (the `?tellUs=1` shortcut).
  final bool openTellUs;
  const MemoryTabView({super.key, this.openTellUs = false});

  @override
  ConsumerState<MemoryTabView> createState() => _MemoryTabViewState();
}

class _MemoryTabViewState extends ConsumerState<MemoryTabView> {
  /// Which sections the user has collapsed. Absent = expanded, which is the
  /// resting state: the page is meant to be read, not opened section by
  /// section.
  final Set<MemoryParent> _collapsed = <MemoryParent>{};

  /// The avoids section is not a [MemoryParent], so it carries its own flag.
  bool _avoidsCollapsed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(unifiedAnalyticsProvider).trackMemoryOpen();
      if (ref.read(memoryTwinProvider).hasValue) {
        ref.read(memoryTwinProvider.notifier).silentRefresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final twinAsync = ref.watch(memoryTwinProvider);
    return twinAsync.when(
      data: _buildList,
      error: (_, _) => MemoryErrorState(
        onRetry: () => ref.read(memoryTwinProvider.notifier).refresh(),
      ),
      loading: () => const MemorySkeleton(),
    );
  }

  Widget _buildList(MemoryTwinResponse twin) {
    final l10n = Lt.of(context);

    // Same parent grouping the legacy Memory page uses — venue_types is
    // heterogeneous and gets split across parents by each value's category
    // group rather than landing wholesale under Tastes.
    final familiesByParent = <MemoryParent, List<FamilyView>>{};
    for (final family in twin.families) {
      if (family.family == 'venue_types') {
        splitVenueTypesByGroup(family).forEach((parent, fv) {
          familiesByParent.putIfAbsent(parent, () => <FamilyView>[]).add(fv);
        });
      } else if (family.family == eventSubCategoriesFamilyKey) {
        // PROD-3766: sport-* sub-categories belong to the Sport section, not
        // Events — same split the legacy memory screen already does.
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
    // Every avoided value across every parent, collected into one section at
    // the foot of the page.
    final avoided = <AvoidedValue>[];
    for (final parent in memoryParentRenderOrder) {
      // Saved & followed items surface through the values they produced, not
      // as a section of their own.
      if (parent == MemoryParent.savedFollowed) continue;
      // Social is held back from this surface. Its values are PEOPLE, and the
      // bar rows grade everything 1-5 with a -/+ nudge — a meter on a person
      // reads as "you are 3/5 interested in Maria", and the level-1 fold would
      // then hide people for a reason nothing on screen explains. The facts are
      // untouched in the twin (and still listed on the legacy Memory page);
      // this section returns once the design says what a person should look
      // like here.
      if (parent == MemoryParent.social) continue;
      final all = familiesByParent[parent] ?? const <FamilyView>[];
      // Lift the avoided values out before rendering: they get their own
      // section, and leaving them here would render them twice.
      final split = partitionAvoids(all);
      avoided.addAll(split.avoided);
      final families = split.kept;
      // PROD-3766: every main section stays visible — an empty one shows its
      // inviting hint ("Ainda nada por aqui…") instead of vanishing, so the
      // page always presents the full shape of what Soko can remember.
      final hasBody = _hasObservations(families);
      final expanded = !_collapsed.contains(parent);
      sections.add(
        MemorySection(
          title: memorySectionTitle(context, parent),
          expanded: expanded,
          onToggle: () => setState(() {
            if (!_collapsed.remove(parent)) _collapsed.add(parent);
          }),
          child: !hasBody
              ? Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 10),
                  child: Text(
                    memoryParentEmptyHint(context, parent),
                    style: TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontSize: 13,
                      height: 1.35,
                      color: AppColors.sokoInk.withValues(alpha: 0.55),
                    ),
                  ),
                )
              : parent == MemoryParent.location
              ? _locationBody(families)
              : MemoryFamilyBars(
                  families: families,
                  // Desporto's section title already says it — no "Desporto"
                  // group header inside its own section.
                  suppressSubcategoryGroupHeaders:
                      parent == MemoryParent.sportOutdoors,
                  onDelete: _confirmDeleteValue,
                  onNudge: _nudgeValue,
                ),
        ),
      );
    }

    if (avoided.isNotEmpty) {
      sections.add(
        MemorySection(
          title: l10n.memorySectionTitleAvoids,
          expanded: !_avoidsCollapsed,
          onToggle: () => setState(() => _avoidsCollapsed = !_avoidsCollapsed),
          child: MemoryAvoidChips(
            values: avoided,
            onDelete: _confirmDeleteAvoid,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 32),
      children: [
        if (twin.personaTags.isNotEmpty) ...[
          _Heading(l10n.memoryPersonaHeading),
          PersonaFlatCard(personaTags: twin.personaTags),
          const SizedBox(height: 8),
        ],
        if (_memoryBio() case final bio? when bio.isNotEmpty) ...[
          _Heading(l10n.memoryLikesHeading),
          MemoryBioProse(text: bio),
          const SizedBox(height: 16),
        ],
        MemoryTellUsCard(compact: true, startExpanded: widget.openTellUs),
        ...sections,
      ],
    );
  }

  /// Localização opens with the home row ("Tu estás baseado em: …") pulled out
  /// of the `location.home` dimension — it is a fact about you, not a graded
  /// preference, so it never renders as a bar. Everything else in the parent
  /// (frequent areas) follows as normal bars.
  Widget _locationBody(List<FamilyView> families) {
    String? home;
    final rest = <FamilyView>[];
    for (final family in families) {
      final dims = <DimensionView>[];
      for (final dim in family.dimensions) {
        if (dim.name == 'location.home' && dim.observations.isNotEmpty) {
          home ??= humanizeMemoryValue(
            context,
            dim.observations.first.value,
            family: dim.family,
          );
          continue;
        }
        dims.add(dim);
      }
      if (dims.isNotEmpty) {
        rest.add(FamilyView(family: family.family, dimensions: dims));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The row renders the shared location line, which reads the search
        // location itself — `home` is still pulled out of the dimension above
        // so the same place doesn't also appear as a bar underneath.
        if (home != null) const MemoryHomeRow(),
        MemoryFamilyBars(
          families: rest,
          onDelete: _confirmDeleteValue,
          onNudge: _nudgeValue,
        ),
      ],
    );
  }

  /// The LLM memory bio, same source the public profile renders. Never let an
  /// unresolved auth graph take the whole tab down with it.
  String? _memoryBio() {
    try {
      final handle = ref.read(authStateProvider).user?.handle;
      if (handle == null || handle.isEmpty) return null;
      return ref.watch(publicProfileProvider(handle)).valueOrNull?.memoryBio;
    } catch (_) {
      return null;
    }
  }

  bool _hasObservations(List<FamilyView> families) {
    for (final family in families) {
      for (final dim in family.dimensions) {
        if (dim.observations.isNotEmpty) return true;
      }
    }
    return false;
  }

  Future<void> _confirmDeleteValue(
    DimensionView dimension,
    ObservationView obs,
  ) async {
    // Quote the label the user is looking at. `obs.value` is the canonical
    // token ("casual_hangout"), which leaked into the sheet while the chip
    // beside it showed the humanized name.
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

  /// Same write as [_confirmDeleteValue] — only the confirmation copy differs,
  /// because removing an avoid un-blocks a value rather than forgetting a like.
  Future<void> _confirmDeleteAvoid(
    DimensionView dimension,
    ObservationView obs,
  ) async {
    final ok = await showMemoryDeleteAvoidSheet(
      context,
      quoted: humanizeMemoryValue(context, obs.value, family: dimension.family),
    );
    if (!ok) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackMemoryDelete(tag: obs.value, category: dimension.family);
    await ref.read(memoryTwinProvider.notifier).suppressChip(dimension, obs);
  }

  Future<void> _nudgeValue(
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
}

/// A SeasonMix display heading ("A tua persona", "O que tu gostas").
class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 12),
    child: Text(text, style: Pt.display.copyWith(fontSize: 30, height: 1.1)),
  );
}

/// The empty tab: no memory yet, just the invitation to write some.
class MemoryTabEmpty extends StatelessWidget {
  const MemoryTabEmpty({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SokoBrainIcon(size: 18, color: AppColors.sokoShade3),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              Lt.of(context).memoryAddToMemories,
              style: Pt.b2.copyWith(color: AppColors.sokoShade3),
            ),
          ),
        ],
      ),
    ),
  );
}
