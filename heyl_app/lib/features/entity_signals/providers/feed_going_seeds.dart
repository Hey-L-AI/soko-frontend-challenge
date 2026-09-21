// The feed's friends-going seeds — the sibling of `feed_signal_seeds.dart`.
//
// The Discovery feed response carries a sibling `going` map (the "Dos teus
// amigos" line): which of the viewer's friends are interested in each event on
// the page. This store carries that map from the feed provider to the bundle
// rows, so a row can draw "John vai" from the page that delivered it.
//
// Simpler than the sentiment seeds in two ways, both because a going entry is
// present-or-absent with no "none" state:
//   * only entries the backend actually sent are stored — an absent event id
//     means "no friend interested", which the row renders as no line at all, so
//     there is nothing to seed for coverage;
//   * it is events-only.
// It keeps the same per-composition generation token, for the same reason: a
// slow page-1 response must lose to the composition that superseded it.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/feed_home.dart';

class FeedGoingSeeds extends Notifier<Map<String, FeedGoingEntry>> {
  @override
  Map<String, FeedGoingEntry> build() {
    // Riverpod reuses this notifier across a rebuild, so the user-scoped purge
    // clears `state` and leaves `_generation` alone. Without this bump, a feed
    // composition started by the PREVIOUS viewer still matches the live token
    // and writes their seeds into ours — and a present seed SUPPRESSES the
    // per-entity GET that would correct it (PROD-4527).
    _generation++;
    return const {};
  }

  /// Which feed composition currently owns this store. Lives here rather than on
  /// the autoDispose feed notifier, which mints a new instance (and fresh
  /// counters) on every invalidation — see `FeedSignalSeeds`.
  int _generation = 0;

  int get currentToken => _generation;

  /// Mints a token for a STARTING composition, synchronously before any await,
  /// so the token records start order rather than completion order.
  int beginComposition() => ++_generation;

  /// Folds one feed page's `going` map into the store, if [token] still owns it.
  ///
  /// [resetFirst] is true for the first page of a composition: the feed was
  /// recomposed from scratch, so entries from the feed the user left must not
  /// answer for rows in the new one.
  void applyPage(int token, FeedGoing? going, {required bool resetFirst}) {
    if (token != _generation) return;
    if (resetFirst) clear();
    mergePage(going);
  }

  /// Merges rather than replaces: each cursor page carries only its own events,
  /// and rows from earlier pages stay mounted.
  ///
  /// A response that carried no `going` key at all (null) cannot answer for
  /// this page and is ignored — the rows keep whatever they already had rather
  /// than losing their lines to an older backend's silence.
  void mergePage(FeedGoing? going) {
    if (going == null || going.events.isEmpty) return;
    state = {...state, ...going.events};
  }

  /// Drops every entry. Called when the feed is recomposed from scratch — a
  /// filter or location change — so lines from a feed the user left cannot
  /// answer for rows in the new one.
  void clear() {
    if (state.isEmpty) return;
    state = const {};
  }
}

final feedGoingSeedsProvider =
    NotifierProvider<FeedGoingSeeds, Map<String, FeedGoingEntry>>(
      FeedGoingSeeds.new,
    );
