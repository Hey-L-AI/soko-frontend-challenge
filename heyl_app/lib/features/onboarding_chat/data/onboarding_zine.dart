import '../../../data/models/saved_item.dart';
import '../../lists/utils/zine_cover_recipe.dart';

/// One hidden, generated "preliminary" onboarding zine (PROD-3883 / BE-2).
///
/// The endpoint returns ONE themed zine per interest the user picked (see
/// [listFromResponse]); each is an `onboarding_preliminary` list ([listId])
/// materialized for the user's onboarding city, carrying its cover recipe and
/// [items] (places/events). It is NOT auto-saved — the client renders the zines
/// as a row of preview covers and calls the save endpoint to keep one.
class OnboardingPreliminaryZine {
  const OnboardingPreliminaryZine({
    required this.listId,
    required this.name,
    required this.itemCount,
    required this.items,
    this.coverType,
    this.coverColor,
    this.coverTexture,
    this.coverTextColor,
    this.coverImageUrl,
    this.coverItemImageUrl,
    this.coverShowTitle = true,
    this.coverShowTexture = true,
    this.coverShowLogo = true,
    this.ownerHandle,
    this.description,
    this.ownerName,
    this.ownerId,
    this.ownerAvatarUrl,
    this.ownerIsExpert = false,
  });

  /// The hidden `onboarding_preliminary` list id — the save endpoint's target.
  final String listId;
  final String name;
  final int itemCount;
  final List<SavedItem> items;

  /// Owner handle for zines authored by other users (the "most-followed" batch
  /// — see [OnboardingSuggestedZinesApi]). Null for the generated preliminary
  /// zines, which carry no owner and render the "Curated for you" line instead.
  final String? ownerHandle;

  /// Zine description — the card's bottom line (Ink @ 50%). Populated only for
  /// the most-followed batch (mapped from `UserList.description`); the generated
  /// `PreliminaryZine` schema carries no description, so this stays null there
  /// and the card omits the line (OpenAPI gap — see docs/openapi-gaps.md).
  final String? description;

  /// Owner display name + stable id + expert flag, for the editor attribution
  /// row (avatar + "Edt. {name}"). Populated only for the most-followed batch
  /// (from `UserList`); null for the generated batch. [ownerAvatarUrl] is null
  /// only when that owner has uploaded no photo — the row then falls back to a
  /// seeded initial-letter dot keyed on [ownerId]. (This said "avatar photos
  /// are absent backend-wide (PROD-1703)" long after the backend started
  /// sending `owner.avatar_url`.)
  final String? ownerName;
  final String? ownerId;
  final String? ownerAvatarUrl;
  final bool ownerIsExpert;

  // BE cover recipe (mirrors `PreliminaryZine` in the OpenAPI spec) so the
  // preview cover renders without a second fetch — resolved via [coverRecipe].
  final String? coverType;
  final String? coverColor;
  final String? coverTexture;
  final String? coverTextColor;
  final String? coverImageUrl;

  /// Server-resolved, already-proxied image URL for an `item_image` cover
  /// (mirrors `UserListOut.cover_item_image_url`, PROD-1932). This is the
  /// canonical source the cover recipe's `item_image` branch reads — the
  /// legacy `cover_image_url` channel is NOT consulted for `item_image`
  /// covers, so without threading this through the carousel cover rendered
  /// solid-colour and never fetched the photo. See [coverRecipe].
  final String? coverItemImageUrl;
  final bool coverShowTitle;
  final bool coverShowTexture;
  final bool coverShowLogo;

  bool get isEmpty => items.isEmpty;

  /// Render-ready recipe for [ListZineCover]. System-curated onboarding zines
  /// ship either an `item_image` cover (photo in [coverItemImageUrl], the
  /// PROD-1932 channel) or an `uploaded_photo` cover (photo in [coverImageUrl],
  /// the legacy channel); solid-colour zines fall back deterministically by
  /// [listId].
  ZineCoverRecipe get coverRecipe => ZineCoverRecipe.fromFields(
    listId: listId,
    coverType: coverType,
    coverColor: coverColor,
    coverTexture: coverTexture,
    coverTextColor: coverTextColor,
    coverItemId: null,
    // The `item_image` cover branch reads `coverItemImageUrl` (or an
    // itemLookup) — NOT `legacyCoverImageUrl`. Pass the BE-resolved item
    // image so themed covers render their photo; fall back to the legacy
    // `cover_image_url` channel so this stays correct whichever field the
    // BE actually populates. Without this the carousel painted a bare
    // colour and fired zero image requests.
    coverItemImageUrl: coverItemImageUrl ?? coverImageUrl,
    legacyCoverImageUrl: coverImageUrl,
    showTitle: coverShowTitle,
    showTexture: coverShowTexture,
    showLogo: coverShowLogo,
  );

  /// Parse the `PreliminaryZinesResponse` wrapper — `{ "zines": [ {...}, ... ] }`
  /// — into the per-interest zine list, in response order. Missing/blank ids are
  /// dropped (nothing to save/preview).
  static List<OnboardingPreliminaryZine> listFromResponse(
    Map<String, dynamic> json,
  ) {
    final raw = (json['zines'] as List?) ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(OnboardingPreliminaryZine.fromJson)
        .where((z) => z.listId.isNotEmpty)
        .toList(growable: false);
  }

  factory OnboardingPreliminaryZine.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List?) ?? const [];
    final owner = json['owner'] as Map<String, dynamic>?;
    return OnboardingPreliminaryZine(
      listId: (json['list_id'] ?? '').toString(),
      name: (json['name'] as String?) ?? '',
      itemCount: (json['item_count'] as num?)?.toInt() ?? rawItems.length,
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(SavedItem.fromJson)
          .toList(growable: false),
      coverType: json['cover_type'] as String?,
      coverColor: json['cover_color'] as String?,
      coverTexture: json['cover_texture'] as String?,
      coverTextColor: json['cover_text_color'] as String?,
      coverImageUrl: json['cover_image_url'] as String?,
      coverItemImageUrl: json['cover_item_image_url'] as String?,
      coverShowTitle: (json['cover_show_title'] as bool?) ?? true,
      coverShowTexture: (json['cover_show_texture'] as bool?) ?? true,
      coverShowLogo: (json['cover_show_logo'] as bool?) ?? true,
      ownerHandle:
          (owner?['handle'] as String?) ?? (json['owner_handle'] as String?),
      description: json['description'] as String?,
      ownerName: owner?['full_name'] as String?,
      ownerId: (owner?['id'] as String?) ?? (json['owner_id'] as String?),
      ownerAvatarUrl: owner?['avatar_url'] as String?,
      ownerIsExpert: (owner?['is_expert'] as bool?) ?? false,
    );
  }
}
