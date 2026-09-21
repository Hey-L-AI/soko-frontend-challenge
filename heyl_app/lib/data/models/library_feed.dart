import 'package:flutter/foundation.dart';

import 'social/follow_user_summary.dart';

/// Pin partition on every library-feed variant (PROD-4103).
enum LibraryPinState {
  notPinned,
  userPinned,
  systemPinned;

  String get wire => switch (this) {
    LibraryPinState.notPinned => 'not_pinned',
    LibraryPinState.userPinned => 'user_pinned',
    LibraryPinState.systemPinned => 'system_pinned',
  };

  static LibraryPinState fromWire(String? value) => switch (value) {
    'user_pinned' => LibraryPinState.userPinned,
    'system_pinned' => LibraryPinState.systemPinned,
    _ => LibraryPinState.notPinned,
  };
}

enum LibraryFeedItemType {
  zine,
  event,
  place,
  person;

  String get wire => name;

  static LibraryFeedItemType? tryParse(String? value) => switch (value) {
    'zine' => LibraryFeedItemType.zine,
    'event' => LibraryFeedItemType.event,
    'place' || 'venue' => LibraryFeedItemType.place,
    'person' => LibraryFeedItemType.person,
    _ => null,
  };
}

@immutable
class LibraryFeedOwner {
  final String handle;
  final String? fullName;
  final String? avatarUrl;

  const LibraryFeedOwner({required this.handle, this.fullName, this.avatarUrl});

  factory LibraryFeedOwner.fromJson(Map<String, dynamic> json) {
    return LibraryFeedOwner(
      handle: json['handle'] as String? ?? '',
      fullName: json['full_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

@immutable
class LibraryFeedSocialProofActor {
  final String? fullName;
  final String? avatarUrl;

  const LibraryFeedSocialProofActor({this.fullName, this.avatarUrl});

  factory LibraryFeedSocialProofActor.fromJson(Map<String, dynamic> json) {
    return LibraryFeedSocialProofActor(
      fullName: json['full_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

enum LibrarySocialProofKind { followedBy, mutualFollows }

@immutable
class LibraryFeedSocialProof {
  final LibrarySocialProofKind kind;
  final int? count;
  final LibraryFeedSocialProofActor? actor;

  const LibraryFeedSocialProof({required this.kind, this.count, this.actor});

  factory LibraryFeedSocialProof.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] == 'mutual_follows'
        ? LibrarySocialProofKind.mutualFollows
        : LibrarySocialProofKind.followedBy;
    final actorRaw = json['actor'];
    return LibraryFeedSocialProof(
      kind: kind,
      count: json['count'] as int?,
      actor: actorRaw is Map<String, dynamic>
          ? LibraryFeedSocialProofActor.fromJson(actorRaw)
          : null,
    );
  }
}

sealed class LibraryFeedItem {
  String get id;
  LibraryFeedItemType get type;
  LibraryPinState get pinState;

  /// Person pins are not on the wire (v1.121.0). System pins 409 if toggled.
  bool get canTogglePin =>
      type != LibraryFeedItemType.person &&
      pinState != LibraryPinState.systemPinned;

  /// Skip unknown `type` values so a new variant does not fail the page.
  /// A malformed known variant is skipped the same way — one bad row
  /// must not empty the feed.
  static LibraryFeedItem? tryParse(Map<String, dynamic> json) {
    final rawType = json['type'] ?? json['item_type'];
    try {
      switch (rawType) {
        case 'zine':
          return LibraryFeedZine.fromJson(json);
        case 'event':
          return LibraryFeedEvent.fromJson(json);
        case 'place':
        case 'venue':
          return LibraryFeedPlace.fromJson(json);
        case 'person':
          return LibraryFeedPerson.fromJson(json);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

@immutable
class LibraryFeedZine extends LibraryFeedItem {
  @override
  final String id;
  @override
  LibraryFeedItemType get type => LibraryFeedItemType.zine;
  @override
  final LibraryPinState pinState;
  final String name;
  final int itemCount;
  final int? followerCount;
  final LibraryFeedOwner owner;
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverImageUrl;

  /// PROD-2297 curator toggles. `false` on curated artwork (from_profiling,
  /// the save ledgers) so the cover renders without stripe, logo or grain.
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;
  final List<String> previewImages;

  /// Owner setting, not effective visibility. `followers` is a retired
  /// tier — treat unknown values as opaque (PROD-4171).
  final String? visibility;

  /// Up to three viewer-relative follower summaries. Null on the
  /// caller's own zines and when nobody follows.
  final List<FollowUserSummary>? followerPreview;

  LibraryFeedZine({
    required this.id,
    required this.pinState,
    required this.name,
    required this.itemCount,
    required this.owner,
    this.followerCount,
    this.visibility,
    this.followerPreview,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
    this.previewImages = const [],
  });

  factory LibraryFeedZine.fromJson(Map<String, dynamic> json) {
    final ownerRaw = json['owner'];
    return LibraryFeedZine(
      id: _requireId(json),
      pinState: LibraryPinState.fromWire(json['pin_state'] as String?),
      name: json['name'] as String? ?? '',
      itemCount: json['item_count'] as int? ?? 0,
      followerCount: json['follower_count'] as int?,
      visibility: json['visibility'] as String?,
      followerPreview: _followerPreview(json['follower_preview']),
      owner: ownerRaw is Map<String, dynamic>
          ? LibraryFeedOwner.fromJson(ownerRaw)
          : const LibraryFeedOwner(handle: ''),
      coverType: json['cover_type'] as String?,
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      coverShowTitle: json['cover_show_title'] as bool? ?? true,
      coverShowTexture: json['cover_show_texture'] as bool? ?? true,
      coverShowLogo: json['cover_show_logo'] as bool? ?? true,
      previewImages: (json['preview_images'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }
}

@immutable
class LibraryFeedEvent extends LibraryFeedItem {
  @override
  final String id;
  @override
  LibraryFeedItemType get type => LibraryFeedItemType.event;
  @override
  final LibraryPinState pinState;
  final String title;
  final String? imageUrl;
  final DateTime? startAt;
  final DateTime? endAt;
  final bool timeKnown;
  final String? category;
  final String? venueName;

  LibraryFeedEvent({
    required this.id,
    required this.pinState,
    required this.title,
    this.imageUrl,
    this.startAt,
    this.endAt,
    this.timeKnown = true,
    this.category,
    this.venueName,
  });

  factory LibraryFeedEvent.fromJson(Map<String, dynamic> json) {
    return LibraryFeedEvent(
      id: _requireId(json),
      pinState: LibraryPinState.fromWire(json['pin_state'] as String?),
      title: json['title'] as String? ?? '',
      imageUrl: json['image_url'] as String?,
      startAt: _parseDate(json['start_at']),
      endAt: _parseDate(json['end_at']),
      timeKnown: json['time_known'] as bool? ?? true,
      category: json['category'] as String?,
      venueName: json['venue_name'] as String?,
    );
  }
}

@immutable
class LibraryFeedPlace extends LibraryFeedItem {
  @override
  final String id;
  @override
  LibraryFeedItemType get type => LibraryFeedItemType.place;
  @override
  final LibraryPinState pinState;
  final String name;
  final String? imageUrl;
  final String? category;
  final String? address;
  final String? city;

  LibraryFeedPlace({
    required this.id,
    required this.pinState,
    required this.name,
    this.imageUrl,
    this.category,
    this.address,
    this.city,
  });

  factory LibraryFeedPlace.fromJson(Map<String, dynamic> json) {
    return LibraryFeedPlace(
      id: _requireId(json),
      pinState: LibraryPinState.fromWire(json['pin_state'] as String?),
      name: json['name'] as String? ?? '',
      imageUrl: json['image_url'] as String?,
      category: json['category'] as String?,
      address: json['address'] as String?,
      city: json['city'] as String?,
    );
  }
}

@immutable
class LibraryFeedPerson extends LibraryFeedItem {
  @override
  final String id;
  @override
  LibraryFeedItemType get type => LibraryFeedItemType.person;
  @override
  final LibraryPinState pinState;
  final String displayName;
  final String handle;
  final String? avatarUrl;
  final LibraryFeedSocialProof? socialProof;

  LibraryFeedPerson({
    required this.id,
    required this.pinState,
    required this.displayName,
    required this.handle,
    this.avatarUrl,
    this.socialProof,
  });

  factory LibraryFeedPerson.fromJson(Map<String, dynamic> json) {
    final proofRaw = json['social_proof'];
    return LibraryFeedPerson(
      id: _requireId(json),
      pinState: LibraryPinState.fromWire(json['pin_state'] as String?),
      displayName: json['display_name'] as String? ?? '',
      handle: json['handle'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String?,
      socialProof: proofRaw is Map<String, dynamic>
          ? LibraryFeedSocialProof.fromJson(proofRaw)
          : null,
    );
  }
}

@immutable
class LibraryFeedOut {
  final List<LibraryFeedItem> items;
  final String? nextCursor;

  const LibraryFeedOut({required this.items, this.nextCursor});

  factory LibraryFeedOut.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] as List<dynamic>? ?? const [];
    final items = <LibraryFeedItem>[];
    for (final row in raw) {
      if (row is! Map<String, dynamic>) continue;
      final parsed = LibraryFeedItem.tryParse(row);
      if (parsed != null) items.add(parsed);
    }
    return LibraryFeedOut(
      items: items,
      nextCursor: json['next_cursor'] as String?,
    );
  }
}

@immutable
class LibraryPinOut {
  final LibraryFeedItemType type;
  final String id;
  final LibraryPinState pinState;

  const LibraryPinOut({
    required this.type,
    required this.id,
    required this.pinState,
  });

  factory LibraryPinOut.fromJson(Map<String, dynamic> json) {
    return LibraryPinOut(
      type:
          LibraryFeedItemType.tryParse(json['type'] as String?) ??
          LibraryFeedItemType.zine,
      id: _requireId(json),
      pinState: LibraryPinState.fromWire(json['pin_state'] as String?),
    );
  }
}

String _requireId(Map<String, dynamic> json) {
  final id = json['id'] as String?;
  if (id == null || id.isEmpty) {
    throw const FormatException('library row missing id');
  }
  return id;
}

DateTime? _parseDate(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

List<FollowUserSummary>? _followerPreview(dynamic raw) {
  if (raw is! Map<String, dynamic>) return null;
  final items = raw['items'];
  if (items is! List) return null;
  final out = <FollowUserSummary>[];
  for (final row in items) {
    if (row is! Map<String, dynamic>) continue;
    try {
      out.add(FollowUserSummary.fromJson(row));
    } catch (_) {
      continue;
    }
    if (out.length == 3) break;
  }
  return out;
}
