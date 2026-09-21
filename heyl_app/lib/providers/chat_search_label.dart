import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/session.dart';
import '../features/lists/models/search_scope.dart';
import '../l10n/generated/l10n.dart';
import 'city_auto_scope_provider.dart';
import 'city_scope_provider.dart';
import 'resolved_search_location_provider.dart';
import 'session_provider.dart';

/// What the chat search-location indicator should render.
///
/// [name] is a resolved place name; null means nothing resolved. [isUnnamedArea]
/// is true when C IS a real pick that simply has no place name — the picker's
/// point+radius scope where the backend has no covering polygon. The two are
/// deliberately separate: null hides the indicator, while an unnamed area shows
/// the picker's own "Selected area" copy. Collapsing them would either hide a
/// real pick or render an empty pill (which is what it used to do — the area
/// branch returned `''`, a non-null empty string that no caller could tell
/// apart from a real name).
///
/// Resolve to display text with [chatSearchLabelText] — the split exists only
/// because the localized "Selected area" copy needs an `Lt`, which a Riverpod
/// provider has no context to obtain.
typedef ChatSearchLabel = ({String? name, bool isUnnamedArea});

const ChatSearchLabel _noChatSearchLabel = (name: null, isUnnamedArea: false);

/// Resolves the label shown by the chat search-location indicator. Label-first
/// (the session's backend-supplied `search_center` label, which reflects a
/// mid-conversation moved center), falling back to the picker scope
/// (`cityScopeProvider`) then the auto-resolved scope (`cityAutoScopeProvider`).
/// A null [ChatSearchLabel.name] with [ChatSearchLabel.isUnnamedArea] false
/// means nothing resolved — the indicator hides entirely in that case.
///
/// The fallback renders the label **in the same format as the picker pill**
/// (PROD-3200): it mirrors the label built by `resolvedSearchScopeProvider` —
/// city → "City, ISO2", area → the leaf place name `boundaryPlaceLabel`
/// ("Arroios"), country → the country name. The backend `search_center.label`
/// is likewise single-level today.
///
/// Pure function (mirrors [resolveChatSeedLocation]) so it can be unit-tested
/// without Riverpod. See
/// `docs/superpowers/specs/2026-07-16-chat-search-location-indicator-design.md`.
ChatSearchLabel resolveChatSearchLabel({
  required SessionSearchCenter? sessionCenter,
  required SearchScope? pickerScope,
  required SearchScope? autoScope,
}) {
  final label = sessionCenter?.label?.trim();
  if (label != null && label.isNotEmpty) {
    return (name: label, isUnnamedArea: false);
  }
  final picker = _scopeHierarchyLabel(pickerScope);
  if (picker != _noChatSearchLabel) return picker;
  return _scopeHierarchyLabel(autoScope);
}

/// Display label for a scope, matching the pill's `resolvedSearchScopeProvider`
/// formula so chat and the action-bar pill name the same place identically.
ChatSearchLabel _scopeHierarchyLabel(SearchScope? scope) {
  switch (scope) {
    case SearchScopeCountryCity(:final city, :final iso2):
      return (name: '${city.name}, $iso2', isUnnamedArea: false);
    case SearchScopeArea(:final displayName):
      // An area ALWAYS resolves — an empty display name is the unnamed
      // point+radius pick, not "nothing here", so it must not fall through to
      // the auto scope (which names a different place entirely).
      return displayName.trim().isEmpty
          ? (name: null, isUnnamedArea: true)
          : (name: displayName, isUnnamedArea: false);
    case SearchScopeCountry(:final countryName):
      return (name: countryName, isUnnamedArea: false);
    case null:
      return _noChatSearchLabel;
  }
}

/// Display text for a [ChatSearchLabel], or null when the indicator should
/// hide. Kept beside [resolveChatSearchLabel] so the "unnamed area shows the
/// picker's own copy" rule has exactly one implementation; the split exists
/// only because `Lt` needs a [BuildContext] and the provider has none.
String? chatSearchLabelText(ChatSearchLabel label, Lt l10n) {
  final name = label.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  return label.isUnnamedArea ? l10n.locationScopeUnnamedArea : null;
}

/// Live label for the chat search-location indicator. Watches the active
/// session's center and the picker scopes; recomputes when any of them
/// change (e.g. the backend moves `search_center` after a named place).
/// Resolve it with [chatSearchLabelText]; a null result hides the indicator.
final chatSearchLocationLabelProvider = Provider<ChatSearchLabel>((ref) {
  final session = ref.watch(activeSessionProvider);
  // Decision 13 — prefer the follow-U neighbourhood area (what the chat seed C
  // now uses) over the coarser profile/IP city, so the composer label matches
  // the seeded search center instead of showing "Lisboa, PT" for "Arroios".
  final followUser = ref.watch(autoFollowUserScopeProvider).valueOrNull;
  return resolveChatSearchLabel(
    sessionCenter: session?.searchCenter,
    pickerScope: ref.watch(cityScopeProvider),
    autoScope: followUser ?? ref.watch(cityAutoScopeProvider).valueOrNull,
  );
});
