import 'dart:math';

import '../../../data/models/social/user_search_item.dart';

/// Presentation order for the Locals surfaces — a *weighted* shuffle that
/// favours set-up profiles (a photo, and zines) without segregating them.
///
/// ## Why a shuffle at all
///
/// `/users/suggested` returns a deterministically ranked pool, and the shelf
/// takes the top slice, so the same faces win forever. The pool is not small —
/// measured at 7,422 candidates for one account — and the top of it is a wide
/// band of ties: 2 people with three mutual followers, **12 with two**, 46 with
/// one. The shelf shows ten. So eight of those twelve equally-good people fill
/// the row, always the same eight, and the other four never appear.
///
/// ## Why weighted, and not a partition
///
/// The ask was "more profile photos", explicitly NOT "photos first": a hard
/// partition reads as a visible divider — every photo, then every blank — which
/// is worse than the problem. So each person gets a *weight* and the draw
/// favours the heavy ones. Photos surface more often, nothing is guaranteed,
/// and there is no boundary anywhere in the list.
///
/// Relevance is carried two ways. Mutual followers — the backend's PRIMARY
/// sort key, and the strongest reason to show someone at all — get their own
/// term, from the count the row already carries. Everything else the backend
/// weighed (same city, activity, shared tastes) rides in through the rank the
/// row arrived at, which the weight decays down.
///
/// ```
/// weight = (has photo ? kAvatarBoost : 1)
///        * (has zines ? kZineBoost   : 1)
///        * (1 + mutualFollowers * kMutualBoost)
///        / (1 + rank        * kRankDecay)
/// ```
///
/// Multiplying rather than adding is what produces the asked-for order without
/// anyone drawing a line:
///
/// | profile          | weight |
/// |------------------|--------|
/// | photo + zines    | 3.0    |
/// | photo, no zines  | 2.0    |
/// | zines, no photo  | 1.5    |
/// | neither          | 1.0    |
///
/// Photo outranks zines because it was called for twice — "que tenha foto de
/// perfil sempre melhor". Swap the two constants to reverse that.
///
/// The draw is Efraimidis–Spirakis weighted sampling without replacement: give
/// each item the key `random()^(1/weight)` and sort by key descending. An item
/// with twice the weight is twice as likely to come first, at every position,
/// with no re-normalising pass. It is a shuffle, not a sort — two calls with
/// different [Random]s give different orders.
///
/// Deliberately NOT applied to people *search*: there the ranking answers a
/// question the user typed, and rotating it would be wrong. It also could not
/// work — `/users/search` leaves the suggestion metadata empty by design.

/// How much a profile photo multiplies someone's weight.
///
/// The two constants turn out to be near-orthogonal, which is what makes them
/// tunable at all: measured over a 50/50 pool of fifty, **this one alone**
/// decides how much of the visible row has photos, and [kRankDecay] barely
/// moves it.
///
/// | boost | share of the row with a photo |
/// |-------|------------------------------|
/// | 1.6   | 61 %                         |
/// | 2.0   | 65 %                         |
/// | 3.0   | 73 %                         |
///
/// 2.0 — a clear majority against the 50 % a plain shuffle would give, without
/// the row reading as a rule. Push it higher and it drifts back towards the
/// divider the design rejected.
const double kAvatarBoost = 2.0;

/// How much having published a public zine multiplies someone's weight.
///
/// Deliberately BINARY — "has zines", not "has eleven". The count already
/// drives the backend's own activity score (a zine is its heaviest signal, ×3)
/// and therefore the rank this weight divides by; multiplying by the count here
/// too would let one prolific curator own the row.
///
/// 1.5 sits below [kAvatarBoost] so a photo wins a straight fight, which is
/// what was asked for. It is enough to put a curator with a photo clearly ahead
/// of a photo alone (3.0 vs 2.0), and to lift a curator without one above an
/// empty profile (1.5 vs 1.0).
const double kZineBoost = 1.5;

/// How much each mutual follower — someone you follow who also follows them —
/// multiplies the weight. Three mutuals ×3.4, one ×1.8, none ×1.0.
///
/// This is the backend's first sort key and the most honest reason to put a
/// stranger in front of someone, so it is carried EXPLICITLY rather than left
/// to [kRankDecay] to imply. Linear, not diminishing: the counts in play are
/// small (three is a lot) and a curve would be false precision.
const double kMutualBoost = 0.8;

/// How fast weight falls off down the backend's ranking. Carries what
/// [kMutualBoost] does not: same city, activity, shared tastes.
///
/// Gentle at 0.06 — because rank is a *proxy*, and a bad one inside a tie. The
/// real ranking arrives in wide bands: twelve people with the SAME two mutual
/// followers sit at consecutive ranks, equally good by every measure the
/// backend has, and every unit of decay invents a difference between them.
/// That is the original complaint in miniature, so it is worth spending
/// something to avoid.
///
/// Measured on the real band shape (2 people at three mutuals, 12 at two, the
/// rest at one) — how often the top candidate appears, against how unfair the
/// draw is between the twelve equals:
///
/// | mutual boost | decay | top appears | spread among equals |
/// |--------------|-------|-------------|---------------------|
/// | 0 (rank only)| 0.15  | 44 %        | 1.64×               |
/// | 0.8          | 0.06  | 42 %        | **1.33×**           |
/// | 0.8          | 0.03  | 34 %        | 1.20×               |
///
/// Moving the work into [kMutualBoost] buys most of the fairness for almost
/// none of the protection. Pushing decay lower keeps helping, but by 0.03 the
/// best candidate is missing from two visits in three.
const double kRankDecay = 0.06;

/// Orders [ranked] — a page straight from `/users/suggested`, still in backend
/// rank order — for display, using [random] as the source of the draw.
///
/// Returns a new list holding exactly the same people: nothing is dropped,
/// deduplicated or added. Pass a seeded [Random] to make the order reproducible
/// (tests do; the app re-rolls on every return to Discovery).
List<UserSearchItem> shuffleLocals(List<UserSearchItem> ranked, Random random) {
  if (ranked.length < 2) return List.of(ranked);

  final keyed = <_KeyedUser>[];
  for (var rank = 0; rank < ranked.length; rank++) {
    final user = ranked[rank];
    final hasAvatar = (user.avatarUrl ?? '').isNotEmpty;
    final hasZines = user.zinesCount > 0;
    final weight =
        (hasAvatar ? kAvatarBoost : 1.0) *
        (hasZines ? kZineBoost : 1.0) *
        (1 + user.mutualFollowersCount * kMutualBoost) /
        (1 + rank * kRankDecay);
    // Efraimidis–Spirakis: u^(1/w). Heavier weight pushes the key towards 1,
    // so a descending sort is the draw. `u == 0` yields 0 and simply lands
    // last — no special case, and no NaN reachable here since weight > 0.
    keyed.add(_KeyedUser(user, pow(random.nextDouble(), 1 / weight) as double));
  }

  keyed.sort((a, b) => b.key.compareTo(a.key));
  return [for (final k in keyed) k.user];
}

class _KeyedUser {
  const _KeyedUser(this.user, this.key);

  final UserSearchItem user;
  final double key;
}
