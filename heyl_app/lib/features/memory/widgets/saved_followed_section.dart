import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_tag.dart';

/// One entity the user has explicitly saved (place / event) or followed
/// (zine / list). Carries the entity id so the card can navigate to the
/// canonical detail page on tap, plus the backend-hydrated `imageUrl` /
/// `subtitle` so the card renders a real photo + meta when present.
class _SavedEntity {
  final String name;
  final _EntityKind kind;
  final String factId;
  final String? entityId;
  final String? imageUrl;
  final String? subtitle;

  const _SavedEntity({
    required this.name,
    required this.kind,
    required this.factId,
    required this.entityId,
    required this.imageUrl,
    required this.subtitle,
  });
}

enum _EntityKind { venue, event, list, createdList }

/// Saved & Followed surface — three horizontal scrollable rows of wide
/// cards, one row per kind. Visual mirrors the in-chat `VenueCard`: light
/// sokoVenue / sokoEvent / sokoLilac surface, rounded-16 corners, soft
/// shadow, image-on-left + title + small kind tag on the right. The
/// `SokoCardImage` fallback (seed-based colour block) plays the role of
/// the photo when we don't carry an `imageUrl` on memory facts.
class SavedAndFollowedSection extends StatelessWidget {
  final MemoryTwinResponse twin;

  const SavedAndFollowedSection({super.key, required this.twin});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final entities = _collectActionEntities(twin);
    if (entities.isEmpty) return const SizedBox.shrink();

    final venues = entities.where((e) => e.kind == _EntityKind.venue).toList();
    final events = entities.where((e) => e.kind == _EntityKind.event).toList();
    final lists = entities.where((e) => e.kind == _EntityKind.list).toList();
    final created = entities
        .where((e) => e.kind == _EntityKind.createdList)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (venues.isNotEmpty)
          _Row(
            label: l10n.memorySavedFollowedSubheadVenues,
            entities: venues,
            cardColor: AppColors.sokoVenue,
            tagBg: AppColors.sokoEvent,
            tagLabel: 'Place',
            imageKind: SokoEntityKind.venue,
          ),
        if (events.isNotEmpty)
          _Row(
            label: l10n.memorySavedFollowedSubheadEvents,
            entities: events,
            cardColor: AppColors.sokoEvent,
            tagBg: AppColors.sokoVenue,
            tagLabel: 'Event',
            imageKind: SokoEntityKind.event,
          ),
        if (lists.isNotEmpty)
          _Row(
            label: l10n.memorySavedFollowedSubheadLists,
            entities: lists,
            cardColor: AppColors.sokoLilac,
            tagBg: AppColors.sokoYellow,
            tagLabel: 'Zine',
            imageKind: SokoEntityKind.neutral,
          ),
        if (created.isNotEmpty)
          _Row(
            label: l10n.memorySavedFollowedSubheadCreated,
            entities: created,
            cardColor: AppColors.sokoYellow,
            tagBg: AppColors.sokoLilac,
            tagLabel: 'Zine',
            imageKind: SokoEntityKind.neutral,
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final List<_SavedEntity> entities;
  final Color cardColor;
  final Color tagBg;
  final String tagLabel;
  final SokoEntityKind imageKind;

  const _Row({
    required this.label,
    required this.entities,
    required this.cardColor,
    required this.tagBg,
    required this.tagLabel,
    required this.imageKind,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              label.toLowerCase(),
              style: TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.2,
                color: AppColors.sokoInk.withValues(alpha: 0.55),
              ),
            ),
          ),
          SizedBox(
            height: 96,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              scrollDirection: Axis.horizontal,
              itemCount: entities.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) => _Card(
                entity: entities[i],
                cardColor: cardColor,
                tagBg: tagBg,
                tagLabel: tagLabel,
                imageKind: imageKind,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final _SavedEntity entity;
  final Color cardColor;
  final Color tagBg;
  final String tagLabel;
  final SokoEntityKind imageKind;

  const _Card({
    required this.entity,
    required this.cardColor,
    required this.tagBg,
    required this.tagLabel,
    required this.imageKind,
  });

  @override
  Widget build(BuildContext context) {
    final canNavigate = entity.entityId != null;
    final hasSubtitle =
        entity.subtitle != null && entity.subtitle!.trim().isNotEmpty;
    return GestureDetector(
      onTap: canNavigate ? () => _navigate(context, entity) : null,
      child: Container(
        width: 268,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.sokoInk.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: SokoCardImage(
                  imageUrl: entity.imageUrl,
                  seed: entity.entityId ?? entity.factId,
                  kind: imageKind,
                  width: 80,
                  height: 80,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          entity.name,
                          style: const TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.2,
                            letterSpacing: -0.2,
                            color: AppColors.sokoInk,
                          ),
                          maxLines: hasSubtitle ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (hasSubtitle) ...[
                          const SizedBox(height: 2),
                          Text(
                            entity.subtitle!,
                            style: TextStyle(
                              fontFamily: 'ZalandoSans',
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              height: 1.2,
                              color: AppColors.sokoInk.withValues(alpha: 0.65),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                    SokoTag(
                      background: tagBg,
                      child: Text(tagLabel, style: SokoTag.textStyleCompact),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigate(BuildContext context, _SavedEntity entity) {
    final id = entity.entityId;
    if (id == null) return;
    switch (entity.kind) {
      case _EntityKind.venue:
        context.push('/venues/$id');
        break;
      case _EntityKind.event:
        context.push('/events/$id');
        break;
      case _EntityKind.list:
      case _EntityKind.createdList:
        context.push('/lists/$id');
        break;
    }
  }
}

/// Read the twin's top-level `actionFacts` list, dedupe by fact id, and
/// parse the entity name + id from each. Reading from `actionFacts` (rather
/// than scavenging observation backing facts) means label-less zines —
/// freshly created or followed with no items — still appear. Content
/// prefixes are produced by the backend `record_action_memory` helper.
List<_SavedEntity> _collectActionEntities(MemoryTwinResponse twin) {
  final byFactId = <String, _SavedEntity>{};
  for (final fact in twin.actionFacts) {
    if (byFactId.containsKey(fact.id)) continue;
    final parsed = _parseActionContent(fact.content);
    if (parsed == null) continue;
    byFactId[fact.id] = _SavedEntity(
      name: parsed.$1,
      kind: parsed.$2,
      factId: fact.id,
      entityId: fact.entityId,
      imageUrl: fact.entityImageUrl,
      subtitle: fact.entitySubtitle,
    );
  }
  return byFactId.values.toList();
}

(String, _EntityKind)? _parseActionContent(String content) {
  for (final entry in _contentPrefixes.entries) {
    final prefix = entry.key;
    final kind = entry.value;
    if (!content.startsWith(prefix)) continue;
    var name = content.substring(prefix.length);
    if (name.endsWith("'")) name = name.substring(0, name.length - 1);
    if (name.isEmpty) continue;
    return (name, kind);
  }
  return null;
}

const Map<String, _EntityKind> _contentPrefixes = <String, _EntityKind>{
  "Saved venue '": _EntityKind.venue,
  "Saved event '": _EntityKind.event,
  "Followed list '": _EntityKind.list,
  "Created list '": _EntityKind.createdList,
};
