import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../utils/memory_family_label.dart';
import '../utils/memory_hierarchy.dart';
import 'compact_family_section.dart';
import 'saved_followed_section.dart';

/// Top-level Memory page tile, one per [MemoryParent]. Collapsible — tap
/// the header to toggle. Default state is collapsed except for
/// [MemoryParent.savedFollowed], which opens by default because the
/// saved/followed entities are the headline surface.
///
/// Each parent renders as a tinted rounded-16 tile with a Lucide icon on
/// the left, the parent name in `UnJamoBatang` and a hinge mark on the
/// right. The background tint matches the parent's chip palette so the
/// section has a recognisable colour at a glance — green for tastes,
/// blue for vibe, lilac for events, yellow for location, pink for social,
/// neutral for practical, and a soft mixed tone for savedFollowed.
class ParentSection extends StatefulWidget {
  final MemoryParent parent;
  final List<FamilyView> families;
  final MemoryTwinResponse twin;
  final bool initiallyExpanded;
  final String? expandedObservationId;
  final void Function(String observationId) onToggle;
  final void Function(DimensionView dimension, ObservationView observation)
  onDeleteObservation;
  final void Function(
    DimensionView dimension,
    ObservationView observation,
    bool increase,
  )
  onNudgeObservation;
  final void Function(FamilyView family) onClearCategory;

  const ParentSection({
    super.key,
    required this.parent,
    required this.families,
    required this.twin,
    required this.expandedObservationId,
    required this.onToggle,
    required this.onDeleteObservation,
    required this.onNudgeObservation,
    required this.onClearCategory,
    this.initiallyExpanded = false,
  });

  @override
  State<ParentSection> createState() => _ParentSectionState();
}

class _ParentSectionState extends State<ParentSection> {
  late bool _expanded = widget.initiallyExpanded;

  static const Duration _animDuration = Duration(milliseconds: 220);
  static const Curve _animCurve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    final hasBody = _hasRenderableBody();
    final tileBg = memoryParentTileBackground(widget.parent);
    final iconColor = memoryParentChipBackground(widget.parent);

    return Container(
      decoration: BoxDecoration(
        color: tileBg,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.sokoInk.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hasBody
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _IconBubble(
                    icon: memoryParentIcon(widget.parent),
                    color: iconColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          memoryParentLabel(context, widget.parent),
                          style: const TextStyle(
                            color: AppColors.sokoInk,
                            fontFamily: 'UnJamoBatang',
                            fontSize: 22,
                            fontWeight: FontWeight.w400,
                            letterSpacing: -0.5,
                            height: 1.0,
                          ),
                        ),
                        AnimatedSize(
                          duration: _animDuration,
                          curve: _animCurve,
                          alignment: Alignment.topLeft,
                          child: _expanded
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  // Same slot as a populated parent's summary
                                  // (e.g. "venue types · 9"): when there's
                                  // nothing yet, the inviting hint sits here.
                                  child: Text(
                                    hasBody
                                        ? _buildSummary(context)
                                        : memoryParentEmptyHint(
                                            context,
                                            widget.parent,
                                          ),
                                    style: TextStyle(
                                      fontFamily: 'ZalandoSans',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      height: 1.2,
                                      color: AppColors.sokoInk.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                  if (hasBody) _Hinge(expanded: _expanded),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: _animDuration,
            curve: _animCurve,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                    child: _buildBody(context),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  bool _hasRenderableBody() {
    if (widget.parent == MemoryParent.savedFollowed) {
      return _hasActionFacts(widget.twin);
    }
    if (widget.families.isEmpty) return false;
    for (final f in widget.families) {
      for (final d in f.dimensions) {
        if (d.observations.isNotEmpty) return true;
      }
    }
    return false;
  }

  Widget _buildBody(BuildContext context) {
    if (widget.parent == MemoryParent.savedFollowed) {
      return SavedAndFollowedSection(twin: widget.twin);
    }
    return Column(
      children: [
        for (final family in widget.families)
          CompactFamilySection(
            family: family,
            parent: widget.parent,
            expandedObservationId: widget.expandedObservationId,
            onToggle: widget.onToggle,
            onDeleteObservation: widget.onDeleteObservation,
            onNudgeObservation: widget.onNudgeObservation,
            onClearCategory: () => widget.onClearCategory(family),
          ),
      ],
    );
  }

  /// Inline subtitle shown only when the parent is collapsed.
  String _buildSummary(BuildContext context) {
    if (widget.parent == MemoryParent.savedFollowed) {
      return _savedFollowedSummary(context, widget.twin);
    }
    final parts = <String>[];
    for (final f in widget.families) {
      // PROD-3766: count what the section actually shows — distinct chip
      // values on the primary tier — not raw observations (a heavy user had
      // "vibes 597" from one observation per backing fact).
      final count = f.dimensions.fold<int>(0, (sum, d) {
        final values = <String>{
          for (final o in d.observations)
            if (!o.isSecondary) o.value.trim().toLowerCase(),
        };
        return sum + values.length;
      });
      if (count == 0) continue;
      final label = memoryFamilyLabel(context, f.family).toLowerCase();
      parts.add('$label $count');
    }
    return parts.join(' · ');
  }
}

class _IconBubble extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IconBubble({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Center(child: Icon(icon, size: 18, color: AppColors.sokoInk)),
    );
  }
}

/// Counts the unique action-sourced facts in the twin's `actionFacts` list
/// and renders them as "3 places · 1 event · 2 zines". Inline counts
/// skipped when zero in that bucket. Created zines fold into the zine count
/// alongside followed zines for the collapsed summary line.
String _savedFollowedSummary(BuildContext context, MemoryTwinResponse twin) {
  final l10n = Lt.of(context);
  final ids = <String, _SavedKind>{};
  for (final fact in twin.actionFacts) {
    if (ids.containsKey(fact.id)) continue;
    if (fact.content.startsWith("Saved venue '")) {
      ids[fact.id] = _SavedKind.venue;
    } else if (fact.content.startsWith("Saved event '")) {
      ids[fact.id] = _SavedKind.event;
    } else if (fact.content.startsWith("Followed list '") ||
        fact.content.startsWith("Created list '")) {
      ids[fact.id] = _SavedKind.list;
    }
  }
  final parts = <String>[];
  final venues = ids.values.where((k) => k == _SavedKind.venue).length;
  final events = ids.values.where((k) => k == _SavedKind.event).length;
  final lists = ids.values.where((k) => k == _SavedKind.list).length;
  if (venues > 0) {
    parts.add('$venues ${venues == 1 ? "place" : "places"}');
  }
  if (events > 0) {
    parts.add('$events ${events == 1 ? "event" : "events"}');
  }
  if (lists > 0) {
    parts.add('$lists ${lists == 1 ? "zine" : "zines"}');
  }
  if (parts.isEmpty) return l10n.memoryParentSavedFollowed.toLowerCase();
  return parts.join(' · ');
}

bool _hasActionFacts(MemoryTwinResponse twin) => twin.actionFacts.isNotEmpty;

enum _SavedKind { venue, event, list }

/// Thin hinge indicator. Horizontal when the chapter is closed, vertical
/// when open. Reads as "opening" without the settings-list feel of a
/// chevron icon.
class _Hinge extends StatelessWidget {
  final bool expanded;
  const _Hinge({required this.expanded});

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      turns: expanded ? 0.25 : 0,
      child: SizedBox(
        width: 18,
        height: 18,
        child: Center(
          child: Container(
            width: 14,
            height: 1,
            color: AppColors.sokoInk.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// Vertical gap between consecutive parent tiles in the memory list. Used
/// in place of the earlier `ChapterRule` — with each parent now sitting in
/// its own coloured tile, an additional rule between tiles reads as
/// redundant noise. A clean spacer respects the same chapter rhythm.
class ChapterRule extends StatelessWidget {
  const ChapterRule({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 10);
  }
}
