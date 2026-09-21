// PROD-4288 — the `unknown_area` block: "I don't know this area", as the
// backend declares it.
//
// **The app never renders this on its own initiative** (same rule as
// `feed_complete`). The client's own zero-block state is deliberately neutral
// because it cannot tell out-of-coverage from a known-but-empty city from a
// page of block types it can't draw — see `feed_notice_states.dart`. Naming the
// cause requires knowing it, and only the backend does.
//
// So this reads `block.title` / `block.subtitle` with no ARB fallback: copy
// arrives on the wire, backend-localized (D7). A `?? l10n.something` here would
// quietly restore exactly the client-side inference the block type removes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../data/models/feed_home.dart';
import '../../../../../data/models/geo_city.dart';
import '../../../../lists/models/search_scope.dart';
import '../../../../onboarding_chat/widgets/onboarding_not_local_composer.dart';
import '../../../../../providers/city_scope_provider.dart';
import '../../../../../providers/resolved_search_location_provider.dart';
import '../../../../../providers/search_center_commit.dart';
import '../../../../../providers/session_provider.dart';
import '../feed_notice_states.dart';

/// The picker scope a suggestion becomes.
///
/// Top-level and pure so the part with the traps is directly assertable; the
/// commit around it is the picker's own two-step and is copied, not invented.
///
/// ⚠️ **`source: 'local'`, and it has to be.** `_feedCityId` withholds
/// `city_id` from the feed request for a Google-sourced city, so marking this
/// anything else would make the very next request drop the id the backend just
/// handed us and fall back to coordinates — silently undoing the point of
/// sending `city_id` at all.
@visibleForTesting
SearchScopeCountryCity searchScopeForSuggestion(FeedAreaSuggestion s) =>
    SearchScopeCountryCity(
      iso2: s.countryCode,
      countryName: s.countryName,
      city: GeoCity(
        id: s.cityId,
        name: s.name,
        displayName: s.label,
        source: 'local',
        latitude: s.latitude,
        longitude: s.longitude,
        countryCode: s.countryCode,
      ),
    );

class FeedUnknownAreaBlock extends ConsumerWidget {
  final FeedBlockUnknownArea block;

  const FeedUnknownAreaBlock({super.key, required this.block});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = block.title;
    // Nothing to say. Rendering the illustration and 200 px of air announcing
    // nothing is worse than the block simply not being there — the same call
    // `FeedCompleteBlock` makes for a titleless terminal card.
    if (title == null || title.isEmpty) return const SizedBox.shrink();

    return FeedNotice(
      title: title,
      body: block.subtitle,
      actions: block.suggestions.isEmpty
          ? null
          : _SuggestionChips(suggestions: block.suggestions),
    );
  }
}

/// Gap between grid cells, matching the onboarding wrap's spacing.
const double _kChipGap = 6;

/// The suggested cities as a **2-column grid** (Zé, 2026-09-08).
///
/// [NotLocalChip] is the onboarding step's chip verbatim, but not its layout:
/// there it is a right-aligned `Wrap` because it sits in a chat transcript on
/// the user's side. Here there is no transcript, and a wrap gives four chips of
/// four different widths in a ragged column. The grid makes them read as one
/// choice.
///
/// Each chip is stretched to its half-width cell — the chip centres its own
/// label, so a wider box just gives it more room.
///
/// **Odd counts: the orphan sits bottom-left with the right slot empty.** Not
/// centred, not stretched full-width, and never dropped to round down to an
/// even count — the standing rule for every 2-column grid on a Discovery
/// surface, and a stretched last chip would read as a different, more important
/// action than the three above it.
class _SuggestionChips extends ConsumerWidget {
  final List<FeedAreaSuggestion> suggestions;

  const _SuggestionChips({required this.suggestions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget cell(FeedAreaSuggestion s) => NotLocalChip(
      key: Key('feed-unknown-area-city-${s.cityId}'),
      // Verbatim. The backend owns this string end to end, suffix included;
      // the app does not split it or look up the country.
      label: s.label,
      // Bounded by its grid cell, so the label may auto-shrink rather than
      // overflow it — see the parameter's own note.
      fillWidth: true,
      onTap: () => _apply(ref, s),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < suggestions.length; i += 2)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : _kChipGap),
            child: Row(
              // NOT `CrossAxisAlignment.stretch`: this Column sits in an
              // unbounded-height parent, so stretching asks the Row for an
              // infinite cross-axis extent and layout asserts. The chip pins
              // its own 30 px height anyway — `Expanded` supplies the only
              // thing the cells actually need, which is equal width.
              children: [
                Expanded(child: cell(suggestions[i])),
                const SizedBox(width: _kChipGap),
                Expanded(
                  child: i + 1 < suggestions.length
                      ? cell(suggestions[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Change the search scope for real — the same write the location picker
  /// performs, so a tap here is indistinguishable from picking that city
  /// (Zé, decision 2). The header flips to the city and every other surface
  /// (map, Procura, shelves) follows, because they all read the same scope.
  ///
  /// Routed through [commitSearchCenterChange] rather than setting the scope
  /// directly, so the active chat's search centre moves with it — the picker's
  /// own path does this, and skipping it would leave the chat anchored to an
  /// area the rest of the app has left.
  Future<void> _apply(WidgetRef ref, FeedAreaSuggestion s) async {
    final scope = searchScopeForSuggestion(s);

    // ⚠️ Every `ref.read` happens BEFORE the first await. The feed rebuilds
    // constantly and this block can be gone by the time the commit resolves —
    // reading through a `WidgetRef` after its element is disposed throws, and
    // the failure would land in the second half of a two-step scope change,
    // i.e. chat moved, app not. Captured up front, nothing to be stale.
    final resolved = ref.read(
      resolvedSearchScopeProvider((scope: scope, isExplicit: true)).future,
    );
    final sessions = ref.read(sessionsProvider.notifier);
    final cityScope = ref.read(cityScopeProvider.notifier);

    try {
      await commitSearchCenterChange(
        persistActiveChat: () async =>
            sessions.persistActiveChatSearchCenter(await resolved),
        publishGlobal: () => cityScope.set(scope),
      );
    } catch (error) {
      // Abort rather than publish anyway — the same call the picker makes.
      // Publishing the global scope after the chat leg failed would leave the
      // chat anchored to an area the rest of the app has left, which is the
      // split-brain the two-step commit exists to prevent.
      //
      // No toast: the picker shows one, but its string is hardcoded English
      // and this is a new user-facing path, so surfacing it here would mean
      // either shipping an unlocalized string or inventing an ARB key for an
      // error nobody has specified. The chip simply does nothing, which is
      // what it did before the tap.
      debugPrint('[Feed] unknown_area suggestion (${s.cityId}) failed: $error');
    }
  }
}
