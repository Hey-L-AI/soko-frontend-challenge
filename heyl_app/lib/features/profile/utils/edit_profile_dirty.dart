/// Whether the edit-profile form differs from what was loaded (PROD-3806).
///
/// Pure so the rule can be tested without mounting the screen — and because
/// getting it wrong is silent in both directions: too eager and every back tap
/// interrogates the user, too lax and edits vanish without a word.
///
/// Every editable field is compared, including the three social links, which
/// the screen tracks in controllers but had no captured original for (the
/// analytics `fields_changed` payload doesn't cover them either). Trimmed on
/// both sides so trailing whitespace alone is not "a change" — the save trims
/// too, so it would be a prompt about nothing.
class EditProfileSnapshot {
  final String name;
  final String handle;
  final String bio;
  final String city;
  final String instagram;
  final String tiktok;
  final String website;
  final bool isPrivate;
  final bool showBioMemories;
  final bool showSaved;

  const EditProfileSnapshot({
    required this.name,
    required this.handle,
    required this.bio,
    required this.city,
    required this.instagram,
    required this.tiktok,
    required this.website,
    required this.isPrivate,
    required this.showBioMemories,
    required this.showSaved,
  });

  bool _sameText(String a, String b) => a.trim() == b.trim();

  /// True when [other] holds different values — order-independent, so it reads
  /// the same whichever side is called "the original".
  bool differsFrom(EditProfileSnapshot other) =>
      !_sameText(name, other.name) ||
      !_sameText(handle, other.handle) ||
      !_sameText(bio, other.bio) ||
      !_sameText(city, other.city) ||
      !_sameText(instagram, other.instagram) ||
      !_sameText(tiktok, other.tiktok) ||
      !_sameText(website, other.website) ||
      isPrivate != other.isPrivate ||
      showBioMemories != other.showBioMemories ||
      showSaved != other.showSaved;
}

/// Whether leaving now would lose work.
///
/// [pickedAvatar] is separate from the snapshot because a picked-but-unsaved
/// photo has no "original" to compare against — its mere presence is the
/// change, and it is the one edit a user would be most annoyed to lose.
bool hasUnsavedProfileChanges({
  required EditProfileSnapshot original,
  required EditProfileSnapshot current,
  required bool pickedAvatar,
}) => pickedAvatar || current.differsFrom(original);
