import '../../core/utils/datetime_parsing.dart';
import 'entity_signal.dart';

/// One thumbs-able card in the onboarding "Qual é a tua vibe" step.
///
/// Fed from the unified discovery endpoint (`POST /api/v1/app/discovery`,
/// `entity_types: both`), which returns venues (*Sítios*) and events (*Eventos*)
/// in one ranked list. [entityId] is the target of the
/// `POST /venues|events/{id}/signal` call each 👍/👎 fires.
enum VibeCandidateType {
  place,
  event;

  SignalEntityType get signalType => this == VibeCandidateType.event
      ? SignalEntityType.event
      : SignalEntityType.venue;
}

class VibeCandidate {
  const VibeCandidate({
    required this.type,
    required this.entityId,
    required this.name,
    this.imageUrl,
    this.subtitle = '',
    this.startsAt,
  });

  final VibeCandidateType type;

  /// Venue or event UUID — the signal target.
  final String entityId;
  final String name;
  final String? imageUrl;

  /// Single-line area/category line under the title (matches the Figma card).
  final String subtitle;

  /// Event start (events only) — drives the card's date sticker. Null for
  /// venues or when the payload carried no parseable date.
  final DateTime? startsAt;

  /// A `DiscoveryItem` from `POST /discovery`: `entity_type` + `id` + `title`
  /// plus a free-form `entity` payload we read tolerantly for the image + area
  /// line + event start. The event start lives under `start_at` (the same key
  /// `DiscoveryForYouItem.fromJson` reads off this endpoint), NOT the saved-item
  /// serializer's `start_datetime`/`date` — those are kept only as fallbacks.
  factory VibeCandidate.fromDiscoveryItem(Map<String, dynamic> json) {
    final isEvent = json['entity_type'] == 'events';
    final entity =
        (json['entity'] as Map?)?.cast<String, dynamic>() ?? const {};

    String? str(String key) {
      final v = entity[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final id = (json['id'] as String?) ?? entity['id']?.toString() ?? '';
    final name =
        (json['title'] as String?) ?? str('name') ?? str('title') ?? '';

    return VibeCandidate(
      type: isEvent ? VibeCandidateType.event : VibeCandidateType.place,
      entityId: id,
      name: name,
      imageUrl: str('image_url') ?? str('cover_image_url'),
      subtitle: _composeSubtitle(entity, isEvent: isEvent),
      startsAt: isEvent
          ? parseBackendDateTime(
              str('start_at') ?? str('start_datetime') ?? str('date'),
            )
          : null,
    );
  }

  /// One item of the onboarding hydrate response
  /// (`POST /onboarding/entities/hydrate`): `item_type` (`place`|`event`) +
  /// `event_id`/`venue_id` + an `event`/`venue` payload that shares the same
  /// serialized shape as a discovery item's `entity` (read tolerantly for the
  /// image + area line + event start). The sibling `sentiment` is parsed by the
  /// caller. Event start is read from `start_at` first (matching the discovery
  /// payload), falling back to `start_datetime`/`date` for older shapes.
  factory VibeCandidate.fromHydratedEntity(Map<String, dynamic> json) {
    final isEvent = json['item_type'] == 'event';
    final entity =
        ((isEvent ? json['event'] : json['venue']) as Map?)
            ?.cast<String, dynamic>() ??
        const {};

    String? str(String key) {
      final v = entity[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final id =
        (isEvent ? json['event_id'] : json['venue_id']) as String? ??
        entity['id']?.toString() ??
        '';
    final name = str('name') ?? str('title') ?? '';

    return VibeCandidate(
      type: isEvent ? VibeCandidateType.event : VibeCandidateType.place,
      entityId: id,
      name: name,
      imageUrl: str('image_url') ?? str('cover_image_url'),
      subtitle: _composeSubtitle(entity, isEvent: isEvent),
      startsAt: isEvent
          ? parseBackendDateTime(
              str('start_at') ?? str('start_datetime') ?? str('date'),
            )
          : null,
    );
  }

  /// Builds the card's `"<type> · <location>"` line from the (opaque) discovery
  /// / hydrate `entity` payload, mirroring the search rows'
  /// `type · (neighborhood ?? city)` shape (`_ResultRow._subtitle`,
  /// `ItemSuggestion.typeLabel`).
  ///
  /// Reads the keys the backend actually sends: events carry a `categories`
  /// array (and, once the BE adds it, a localized singular `category`); venues
  /// carry a raw `types` array (and, once added, human `tags`/`facets`). Both
  /// carry `city`, and `neighborhood` once the BE emits it — so this upgrades
  /// from `type · city` to `type · neighborhood` automatically when the richer
  /// fields land, and stays empty (as before) when nothing is present.
  static String _composeSubtitle(
    Map<String, dynamic> entity, {
    required bool isEvent,
  }) {
    String? str(String key) {
      final v = entity[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    String? listFirst(String key) {
      final v = entity[key];
      if (v is List) {
        for (final e in v) {
          if (e is String && e.isNotEmpty) return e;
        }
      }
      return null;
    }

    // Both branches prefer the backend's localized singular `category` label
    // (set by the discovery handler) and fall back to humanizing the raw array
    // that ships today, so the subtitle works before AND after the BE enrich.
    final type = isEvent
        ? (str('category') ?? _humanizeType(listFirst('categories')))
        : (str('category') ??
              listFirst('tags') ??
              listFirst('facets') ??
              _humanizeType(listFirst('types')));
    final location = str('neighborhood') ?? str('city');
    return [type, location].where((s) => s != null && s.isNotEmpty).join(' · ');
  }

  /// `snake_case` / lowercase raw type → `Title Case` (e.g. `ice_cream_shop` →
  /// `Ice Cream Shop`). Mirrors `ItemSuggestion.typeLabel`'s humanization.
  static String? _humanizeType(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return raw
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}

/// A page of the vibe step's two carousels, split out of the discovery result
/// by `entity_type`. The discovery endpoint is not paginated, so [hasMore] is
/// always false — the single ranked set fills both carousels.
class VibeCandidatesResponse {
  const VibeCandidatesResponse({
    required this.venues,
    required this.events,
    required this.offset,
    required this.limit,
    required this.hasMore,
  });

  final List<VibeCandidate> venues;
  final List<VibeCandidate> events;
  final int offset;
  final int limit;
  final bool hasMore;
}
