import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/discovery_facets.dart';
import '../../../data/models/map_pin.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../discovery/utils/facet_labels.dart';
import '../models/map_query.dart';
import '../providers/discovery_facets_provider.dart';
import '../providers/map_query_provider.dart';

/// PROD-2735 — the two-layer **Tema** facet picker, shown as the shared modal
/// bottom sheet (hides the bottom nav). Left column = primary facets, right =
/// the entity-appropriate secondary facets (venue / event / both → union).
///
/// Selection model:
/// - tap a **primary** → selects all its secondaries (tap again → clears them);
/// - tap a **secondary** → selects it + lights its primary, siblings untouched.
///
/// Applies on **"Ok"** (returns the `{parent, child}` set); dismiss = no change.
Future<Set<FacetPair>?> showTemaSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  // Flag the map screen to shield the (web) Mapbox canvas with a
  // PointerInterceptor while the sheet is open, so drags don't bleed through.
  ref.read(mapModalOpenProvider.notifier).state = true;
  try {
    return await showBottomSheetWithHiddenNav<Set<FacetPair>>(
      context: context,
      ref: ref,
      builder: (_) => const _TemaFacetSheet(),
    );
  } finally {
    ref.read(mapModalOpenProvider.notifier).state = false;
  }
}

class _TemaFacetSheet extends ConsumerStatefulWidget {
  const _TemaFacetSheet();

  @override
  ConsumerState<_TemaFacetSheet> createState() => _TemaFacetSheetState();
}

class _TemaFacetSheetState extends ConsumerState<_TemaFacetSheet> {
  // parentId → selected child slugs. Key present ⟺ the primary is lit. An
  // empty set under a childless parent ⟺ a whole-parent selection.
  final Map<String, Set<String>> _sel = {};

  // Snapshot of [_sel] taken when the drawer opened — used to decide whether
  // the user has made any change (so the "Ok" button highlights in pink).
  late final Map<String, Set<String>> _initialSel;

  @override
  void initState() {
    super.initState();
    for (final f in ref.read(mapQueryProvider).facetFilters) {
      final set = _sel.putIfAbsent(f.parent, () => <String>{});
      if (f.child != null) set.add(f.child!);
    }
    // Deep copy so later mutations of [_sel] don't leak into the baseline.
    _initialSel = {
      for (final e in _sel.entries) e.key: {...e.value},
    };
  }

  /// True once the current selection differs from what it was when the drawer
  /// opened (any facet added or removed). Drives the pink "Ok" highlight.
  bool get _hasChanges {
    if (_sel.length != _initialSel.length) return true;
    for (final entry in _sel.entries) {
      final baseline = _initialSel[entry.key];
      if (baseline == null || baseline.length != entry.value.length) {
        return true;
      }
      if (!baseline.containsAll(entry.value)) return true;
    }
    return false;
  }

  ({bool venue, bool event}) get _wants {
    final type = ref.read(mapQueryProvider).type;
    return (
      venue: type == MapItemType.all || type == MapItemType.places,
      event: type == MapItemType.all || type == MapItemType.events,
    );
  }

  List<DiscoveryFacetChild> _childrenFor(DiscoveryParentFacet p) =>
      p.childrenFor(wantVenue: _wants.venue, wantEvent: _wants.event);

  void _tapPrimary(DiscoveryParentFacet p) {
    setState(() {
      final all = _childrenFor(p).map((c) => c.slug).toSet();
      final current = _sel[p.id];
      final allSelected =
          current != null &&
          current.length == all.length &&
          current.containsAll(all);
      if ((allSelected) || (all.isEmpty && current != null)) {
        _sel.remove(p.id); // toggle the whole group off
      } else {
        _sel[p.id] = all; // select all (empty set = childless whole-parent)
      }
    });
  }

  void _tapSecondary(DiscoveryParentFacet p, String slug) {
    setState(() {
      final set = _sel.putIfAbsent(p.id, () => <String>{});
      if (!set.add(slug)) set.remove(slug);
      if (set.isEmpty) _sel.remove(p.id); // last child off → primary off
    });
  }

  Set<FacetPair> _flatten() {
    final out = <FacetPair>{};
    _sel.forEach((parent, slugs) {
      if (slugs.isEmpty) {
        out.add(FacetPair(parent: parent)); // childless whole-parent
      } else {
        for (final s in slugs) {
          out.add(FacetPair(parent: parent, child: s));
        }
      }
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final facetsAsync = ref.watch(discoveryFacetsProvider);

    return DSSheetShell(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(15, 4, 15, 8),
        child: Text(
          l10n.mapTema,
          style: AppTheme.displayPrimary(
            fontSize: 32,
            color: AppColors.sokoInk,
          ),
        ),
      ),
      // Phase C (D7): no sticky footer — the "Ok" apply button floats over
      // the bottom of the facet list (see the `data` branch below).
      body: facetsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, __) => Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: Text(l10n.mapNoResults)),
        ),
        data: (facets) {
          final parents = facets.parents
              .where((p) => p.visibleInFilters)
              .toList();
          if (parents.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(l10n.mapNoResults)),
            );
          }
          return Stack(
            children: [
              ListView.separated(
                // Extra bottom padding clears the floating "Ok" button
                // (h40 + 12 px inset + gap) so the last facet row is never
                // hidden behind it.
                padding: const EdgeInsets.fromLTRB(15, 4, 15, 72),
                itemCount: parents.length,
                separatorBuilder: (_, __) => const SizedBox(height: 18),
                itemBuilder: (_, i) {
                  final p = parents[i];
                  return _ParentGroup(
                    // PROD-2671: localize parent + child chip labels via the
                    // two-layer facet `label_key` (falls back to the backend
                    // English label). Same keys as the pin captions.
                    label: mapFacetLabel(
                      l10n,
                      labelKey: p.labelKey,
                      fallbackLabel: p.label,
                    ),
                    children: _childrenFor(p),
                    selectedChildren: _sel[p.id] ?? const {},
                    primaryLit: _sel.containsKey(p.id),
                    onPrimary: () => _tapPrimary(p),
                    onSecondary: (slug) => _tapSecondary(p, slug),
                  );
                },
              ),
              // Phase C (D7 / Figma 6917-21106): the "Ok" apply button floats
              // bottom-centred over the list instead of a full-width sticky
              // footer.
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Center(
                  child: _FloatingApplyButton(
                    label: l10n.mapTemaApply,
                    // Pink once the user has changed the selection vs. the
                    // state the drawer opened in.
                    highlighted: _hasChanges,
                    onTap: () =>
                        Navigator.of(context).pop<Set<FacetPair>>(_flatten()),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The Tema **"Ok"** apply button (Figma `6917-21106`) — a small DS [BtSqIco]
/// (`Icons.check` + "Ok") that **floats** over the bottom of the facet list
/// rather than sitting in a full-width sticky footer (Phase C, D7). The paper
/// backing + soft shadow (matching the sheet's own shadow language) keep it
/// legible and lifted as list content scrolls behind.
///
/// [highlighted] flips the button from `idle` (ink@6% border) to `selected`
/// (Soko/Pink) once the user has changed the facet selection vs. the state the
/// drawer opened in — signalling there's a pending change to apply.
class _FloatingApplyButton extends StatelessWidget {
  const _FloatingApplyButton({
    required this.label,
    required this.onTap,
    required this.highlighted,
  });

  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: AppColors.sokoInk.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: BtSqIco(
        icon: Icons.check,
        label: label,
        variant: highlighted ? BtSqIcoVariant.selected : BtSqIcoVariant.idle,
        onTap: onTap,
      ),
    );
  }
}

/// One parent row: the primary facet on the left, its secondary facets stacked
/// on the right (top-aligned), as in the design.
class _ParentGroup extends StatelessWidget {
  const _ParentGroup({
    required this.label,
    required this.children,
    required this.selectedChildren,
    required this.primaryLit,
    required this.onPrimary,
    required this.onSecondary,
  });

  final String label;
  final List<DiscoveryFacetChild> children;
  final Set<String> selectedChildren;
  final bool primaryLit;
  final VoidCallback onPrimary;
  final ValueChanged<String> onSecondary;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _FacetChip(
            label: label,
            selected: primaryLit,
            onTap: onPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                _FacetChip(
                  // PROD-2671: localize child chip via its two-layer
                  // `label_key` (falls back to the backend English label).
                  label: mapFacetLabel(
                    l10n,
                    labelKey: children[i].labelKey,
                    fallbackLabel: children[i].label,
                  ),
                  selected: selectedChildren.contains(children[i].slug),
                  onTap: () => onSecondary(children[i].slug),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A facet chip: a 30 px circle (pink when selected, `sokoInk8` when not) with
/// a plus glyph, followed by the localized label.
class _FacetChip extends StatelessWidget {
  const _FacetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.sokoPink : AppColors.sokoInk8,
              ),
              child: const Icon(Icons.add, size: 16, color: AppColors.sokoInk),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(
                  fontSize: 18,
                  fontWeight: FontWeight.w300,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
