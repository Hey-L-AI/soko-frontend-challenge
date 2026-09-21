// PROD-4027 (umbrella PROD-3998) — the feed's sentiment seeds.
//
// The Discovery feed response carries a sibling `signals` map, so the thumbs on
// its cards can paint from the page that delivered them instead of one
// `GET /{entity}/{id}/signal` per card fired *after* the feed lands. This store
// is what carries that map from the feed provider to `SignalController`.
//
// **Why a standalone store rather than reading `feedHomeProvider` directly.**
// `SignalController` is built from surfaces that have nothing to do with the
// feed — chat cards, search rows, onboarding carousels. Having its factory
// `ref.read(feedHomeProvider)` could *instantiate* the feed provider from one
// of those, firing a feed request as a side effect of rendering a chat card.
// This store is inert: reading it cannot cause a request.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/entity_signal.dart';
import '../../../data/models/feed_home.dart';

/// Structurally identical to `SignalKey` in `signal_controller.dart` — Dart
/// records are structural, so the two interoperate without this library
/// importing that one (which imports this one).
typedef FeedSignalSeedKey = ({SignalEntityType type, String id});

/// Sentiment for entities the feed has already told us about.
///
/// **A key present with [SignalTaste.none] is not the same as an absent key.**
/// Present-and-`none` means "the feed covered this entity and the caller has no
/// opinion" — the controller trusts it and skips the GET. Absent means "nothing
/// has told us about this entity", and the controller fetches.
///
/// That distinction is the whole ticket. The backend omits entities with no
/// signal row rather than sending empty objects, so if absence fell through to
/// "unknown", every unrated card — the vast majority — would still fire its own
/// request and the fan-out would survive the fix.
class FeedSignalSeeds extends Notifier<Map<FeedSignalSeedKey, SignalTaste>> {
  @override
  Map<FeedSignalSeedKey, SignalTaste> build() {
    // Riverpod reuses this notifier across a rebuild, so the user-scoped purge
    // clears `state` and leaves `_generation` alone. Without this bump, a feed
    // composition started by the PREVIOUS viewer still matches the live token
    // and writes their seeds into ours — and a present seed SUPPRESSES the
    // per-entity GET that would correct it (PROD-4527).
    _generation++;
    return const {};
  }

  /// Which feed composition currently owns this store.
  ///
  /// The ordering token lives HERE rather than on the feed notifier because
  /// `feedHomeProvider` is `autoDispose` — invalidating it (a filter, location
  /// or account change) builds a **new notifier instance** with its own
  /// counters, so an instance-local version can never tell that an older
  /// instance's in-flight response has been superseded. This store outlives all
  /// of them, so it is the only place that can.
  int _generation = 0;

  /// The token the live feed composition is writing under.
  int get currentToken => _generation;

  /// Mints a token for a feed composition that is STARTING.
  ///
  /// Called synchronously at the top of `build()`, before any await, so the
  /// token records start order rather than completion order — which is the
  /// whole point: a slow page-1 response must lose to the composition that
  /// superseded it, however late it lands. Deliberately does not touch `state`,
  /// so calling it during a provider build cannot trigger a rebuild.
  int beginComposition() => ++_generation;

  /// Folds one feed page into the store, if [token] still owns it.
  ///
  /// [resetFirst] is true for the first page of a composition: the feed was
  /// recomposed from scratch, so seeds from the feed the user left must not
  /// answer for cards in the new one.
  void applyPage(
    int token,
    List<FeedBlock> blocks,
    FeedSignals? signals, {
    required bool resetFirst,
  }) {
    // A newer composition has taken over. Riverpod discards the STATE a
    // superseded build returns, but it cannot undo a side effect that build
    // already performed — this check is what undoes it.
    if (token != _generation) return;
    if (resetFirst) clear();
    mergePage(blocks, signals);
  }

  /// Folds one feed page into the store.
  ///
  /// Merges rather than replaces: each cursor page carries only the ids on that
  /// page, so replacing would drop the seeds for everything already scrolled
  /// past — and those cards stay mounted.
  ///
  /// **Coverage comes from [blocks], not from [signals]** — for BOTH entity
  /// types. Every item the page carries gets a seed, defaulting to
  /// [SignalTaste.none] when the map omits it.
  ///
  /// ⚠️ That direction is the whole ticket and it is easy to get backwards.
  /// Venues used to be seeded by walking `signals.venues` instead, which reads
  /// as equivalent and is not: the backend omits entities the caller has no
  /// opinion on, so a map-driven walk seeds only the *rated* venues and leaves
  /// every unrated one absent — and absent means "fetch". On the Sítios page
  /// that is a grid plus three bundles, i.e. the per-entity fan-out PROD-4027
  /// removed, quietly back for the majority of cards.
  void mergePage(List<FeedBlock> blocks, FeedSignals? signals) {
    // A response that carried no `signals` key cannot answer for anything on
    // this page. Seeding `none` here would suppress the per-entity GETs and
    // leave every card permanently unrated — worse than the fan-out this
    // ticket removes, because nothing would ever correct it.
    if (signals == null) return;

    final additions = <FeedSignalSeedKey, SignalTaste>{};

    for (final id in eventIdsIn(blocks)) {
      additions[(type: SignalEntityType.event, id: id)] = _taste(
        signals.events[id],
      );
    }
    for (final id in venueIdsIn(blocks)) {
      additions[(type: SignalEntityType.venue, id: id)] = _taste(
        signals.venues[id],
      );
    }

    if (additions.isEmpty) return;
    state = {...state, ...additions};
  }

  /// Records the authoritative taste after a successful write.
  ///
  /// The seed store is a cache of "what the server last told us", and a write
  /// is the most recent thing the server told us. Without this, a tap on a feed
  /// card leaves the store holding the pre-tap value; once the autoDispose
  /// controller is collected, the next one reads that stale seed, skips the GET
  /// (the seed is present, so it looks authoritative), and silently reverts the
  /// user's thumb.
  void recordWrite(FeedSignalSeedKey key, SignalTaste taste) {
    if (state[key] == taste) return;
    state = {...state, key: taste};
  }

  /// Drops every seed. Called when the feed is recomposed from scratch — a
  /// filter or location change — so seeds from a feed the user has left cannot
  /// answer for cards in the new one.
  void clear() {
    if (state.isEmpty) return;
    state = const {};
  }

  /// Every **event** id carried by [blocks], in page order.
  ///
  /// ⚠️ **A bundle contributes only when it declares `item_type: 'event'`.**
  /// This used to yield every bundle item id regardless, which was correct
  /// while `event` was the only type the wire emitted and became a bug the
  /// moment venue bundles shipped: a venue id seeded under
  /// [SignalEntityType.event] is an entity that does not exist. Dispatch on the
  /// **declared type, never the active filter** (D34) — the two agree on both
  /// pages today, which is exactly why a filter-based read would pass every
  /// current test.
  ///
  /// A block type this app version cannot parse arrives as [FeedBlockUnknown]
  /// and contributes nothing — correctly: we cannot read its items, so we
  /// cannot claim to know their sentiment, and those cards are not rendered
  /// either.
  static Iterable<String> eventIdsIn(List<FeedBlock> blocks) =>
      _idsOfType(blocks, 'event');

  /// Every **venue** id carried by [blocks], in page order — the `venue_grid`
  /// and any bundle declaring `item_type: 'venue'` (PROD-4108).
  static Iterable<String> venueIdsIn(List<FeedBlock> blocks) =>
      _idsOfType(blocks, 'venue');

  static Iterable<String> _idsOfType(
    List<FeedBlock> blocks,
    String itemType,
  ) sync* {
    for (final block in blocks) {
      switch (block) {
        // The hero has no `item_type` on the wire and is an event by
        // definition, so it answers for `event` alone.
        case FeedBlockEventHero(:final items) when itemType == 'event':
          for (final item in items) {
            yield item.id;
          }
        case FeedBlockBundle(:final items) when block.itemType == itemType:
          for (final item in items) {
            yield item.id;
          }
        case FeedBlockVenueGrid(:final items) when itemType == 'venue':
          for (final item in items) {
            yield item.id;
          }
        default:
          break;
      }
    }
  }

  /// An entity absent from the map has no opinion on it — that is the contract,
  /// and the enum on the wire is `liked` / `disliked` only. An unrecognised
  /// value also lands here rather than throwing.
  static SignalTaste _taste(FeedEntitySignal? signal) => signal == null
      ? SignalTaste.none
      : SignalTaste.fromWire(signal.sentiment);
}

final feedSignalSeedsProvider =
    NotifierProvider<FeedSignalSeeds, Map<FeedSignalSeedKey, SignalTaste>>(
      FeedSignalSeeds.new,
    );
