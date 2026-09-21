import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../l10n/generated/l10n.dart';
import '../providers/people_providers.dart';

/// How many rows before the end the next page starts loading. The request takes
/// about a second (the endpoint re-ranks its whole candidate pool per page), so
/// waiting for the bottom of the list to appear means staring at a spinner for
/// all of it; starting early buys that second back in scrolling the reader was
/// doing anyway.
///
/// Half a page. Android's paging guidance says the prefetch distance "should be
/// several times larger than the page size" and Paging 3 defaults it to a full
/// page, so this is still the conservative end — deliberately, because each
/// page costs the server ~1s and prefetching a full page ahead would fire that
/// for readers who may never scroll. On a tall viewport (desktop web) ten rows
/// can be on screen at once, so the first extra page may load unprompted; it
/// self-limits, since the next marker then sits below the fold.
///
/// A fast flick still outruns it. The real cure is making the page cheap
/// server-side.
const int kSuggestionsPrefetchLookahead = 10;

/// Wraps a row near the end of the list and pulls the next page when that row
/// becomes visible — i.e. before the reader reaches the bottom.
///
/// Visibility, not build order, on purpose: the Find People list is a `Column`
/// (every row builds up front), so an index-based trigger would fire on the
/// first frame and drain the whole ranked pool in one go.
class SuggestionsPrefetch extends ConsumerWidget {
  final Widget child;

  /// Distinguishes this trigger from the other surface's — see
  /// [SuggestionsLoadMore.keyId].
  final String keyId;

  const SuggestionsPrefetch({
    super.key,
    required this.child,
    required this.keyId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return VisibilityDetector(
      key: Key('suggested-users-prefetch-$keyId'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction > 0) {
          ref.read(suggestedUsersPagedProvider.notifier).loadMore();
        }
      },
      child: child,
    );
  }
}

/// Bottom-of-list load-more control for the paginated suggestions: a
/// visibility sentinel that fetches the next page as it scrolls into view, a
/// spinner while a page is in flight, and a retry on failure. Renders nothing
/// once the ranked pool is exhausted.
///
/// Backstop to [SuggestionsPrefetch], which normally has the page already in
/// flight by the time this appears: it still fires for lists shorter than the
/// lookahead, and it is what shows the spinner and the retry. The notifier
/// self-guards, so both firing is harmless.
///
/// Shared by the two surfaces that page through suggestions — the Find People
/// screen and the profile's Locals tab — so they scroll identically and a fix
/// to one is a fix to both.
class SuggestionsLoadMore extends ConsumerWidget {
  final SuggestedUsersState state;

  /// Distinguishes this sentinel from the other surface's. `VisibilityDetector`
  /// wants unique keys, and both surfaces can be mounted at once (Find People
  /// is pushed over the profile).
  final String keyId;

  const SuggestionsLoadMore({
    super.key,
    required this.state,
    required this.keyId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Center(
          child: TextButton(
            onPressed: () =>
                ref.read(suggestedUsersPagedProvider.notifier).retryLoadMore(),
            child: Text(Lt.of(context).commonRetry),
          ),
        ),
      );
    }
    if (!state.hasMore) return const SizedBox.shrink();
    // When this sentinel scrolls into view, pull the next page. The notifier
    // self-guards against concurrent / exhausted / errored load-more calls, so
    // firing on every visibility tick is safe.
    return VisibilityDetector(
      key: Key('suggested-users-load-more-$keyId'),
      onVisibilityChanged: (info) {
        if (info.visibleFraction > 0) {
          ref.read(suggestedUsersPagedProvider.notifier).loadMore();
        }
      },
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
  }
}
