/// Per-(user, entity) relationship signal for a venue or event (PROD-2929).
///
/// Mirrors the backend `SignalOut`. The server owns the toggle: the client
/// POSTs a [SignalAction] and renders the returned state — it never computes
/// the next state locally. Axes: [wantToGo] (the save, DERIVED from saved-list
/// membership — read-only), [dismissedAt] ("not for me"), [markedGoingAt]
/// (event reminder opt-in — its own axis, driven by the reminders API), and
/// [taste] ([went] derives from a rating; there is no standalone Went action).
library;

enum SignalEntityType {
  venue,
  event;

  String get wire => name;
}

/// A signal write — the sentiment chip actions the backend accepts.
///
/// `like` / `dislike` = pure taste (the 👍 / 👎 thumbs). Sentiment is decoupled
/// from attendance: a thumb never asserts `went` (that's a separate write).
/// Saving is the Lists API; going is the reminders API — neither is a chip
/// action. Server owns the toggle (re-sending the held sentiment clears it).
enum SignalAction {
  like('like'),
  dislike('dislike');

  const SignalAction(this.wire);
  final String wire;
}

/// Surface a signal write came from — a soft, last-write-wins attribution label
/// sent as `provenance` on the chip POST (PROD-3888). Lets an onboarding
/// discovery-carousel thumb be told apart from a user search or a detail tap.
/// Free-form on the wire (the backend stores any short string); these are the
/// known values. Add more as new surfaces start attributing themselves.
abstract final class SignalProvenance {
  /// A thumb on the onboarding vibe discovery carousels (Sítios / Eventos).
  static const onboardingDiscovery = 'onboarding_discovery';

  /// A like from the onboarding vibe search overlay or its picks row.
  static const onboardingSearch = 'onboarding_search';

  /// A chip tap on a venue/event detail page.
  static const detail = 'detail';

  /// A thumb on the Daily Drop's own detail page (PROD-3950). Distinct from
  /// [detail] because the drop page is a *recommendation* surface: the entity
  /// was chosen for the user rather than sought out, so a thumb there rates
  /// Soko's pick as much as the place. Keeping the two apart is what lets the
  /// drop's hit-rate be read separately from organic detail-page taste.
  static const dailyDrop = 'daily_drop';

  /// A thumb on a place/event card in the main chat carousel.
  static const chat = 'chat';
}

/// Binary sentiment — the 👍 / 👎 thumbs. No `loved`.
enum SignalTaste {
  none('none'),
  disliked('disliked'),
  liked('liked');

  const SignalTaste(this.wire);
  final String wire;

  static SignalTaste fromWire(String? v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => SignalTaste.none);
}

/// The caller's current relationship state for one entity.
class EntitySignal {
  final SignalEntityType entityType;
  final String entityId;

  /// The save — DERIVED server-side from saved-list membership, read-only here.
  /// Written via the Lists API (add/remove item), never via a signal action.
  final bool wantToGo;
  final DateTime? wantToGoSince;

  /// "Not for me" — a timestamp when set, `null` otherwise. The only stored
  /// intent bit; durable through later ratings.
  final DateTime? dismissedAt;

  final SignalTaste taste;

  /// Attendance — its own axis now, independent of sentiment. Set via a
  /// separate write (justification / save-drawer / prompt), never by a thumb.
  /// Read-only here; the detail-page row no longer sets it.
  final bool went;

  /// The "I have to go" reminder opt-in (events only) — its own axis, set when
  /// non-null. Independent of the save. Driven by the reminders API (the going
  /// writer — never a chip): the backend stamps it on the first reminder and
  /// clears it when the last pending reminder is deleted.
  final DateTime? markedGoingAt;

  /// Occurrence-level going history (events only, read-only). Distinct
  /// occurrence starts the caller ever declared going to via a reminder config.
  /// Append-only — survives clearing going. `0` for venues.
  final int goingMarksCount;

  /// When the caller FIRST declared going to any occurrence of this event.
  /// `null` when never (and for venues).
  final DateTime? firstMarkedGoingAt;

  /// `user` = deliberate action (counts); `system` = algorithmic (never counts).
  final String source;
  final DateTime? createdAt;
  final DateTime? ratedAt;
  final DateTime? updatedAt;

  const EntitySignal({
    required this.entityType,
    required this.entityId,
    this.wantToGo = false,
    this.wantToGoSince,
    this.dismissedAt,
    this.taste = SignalTaste.none,
    this.went = false,
    this.markedGoingAt,
    this.goingMarksCount = 0,
    this.firstMarkedGoingAt,
    this.source = 'user',
    this.createdAt,
    this.ratedAt,
    this.updatedAt,
  });

  /// The neutral state — no signal yet.
  factory EntitySignal.empty(SignalEntityType type, String id) =>
      EntitySignal(entityType: type, entityId: id);

  /// A copy with only [taste] swapped — used for the optimistic thumb flip
  /// before the server confirms. Every other axis is preserved untouched.
  EntitySignal withTaste(SignalTaste next) => EntitySignal(
    entityType: entityType,
    entityId: entityId,
    wantToGo: wantToGo,
    wantToGoSince: wantToGoSince,
    dismissedAt: dismissedAt,
    taste: next,
    went: went,
    markedGoingAt: markedGoingAt,
    goingMarksCount: goingMarksCount,
    firstMarkedGoingAt: firstMarkedGoingAt,
    source: source,
    createdAt: createdAt,
    ratedAt: ratedAt,
    updatedAt: updatedAt,
  );

  bool get hasGoing => markedGoingAt != null;
  bool get isDismissed => dismissedAt != null;

  factory EntitySignal.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) =>
        v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
    return EntitySignal(
      entityType: json['entity_type'] == 'event'
          ? SignalEntityType.event
          : SignalEntityType.venue,
      entityId: json['entity_id'] as String? ?? '',
      wantToGo: json['want_to_go'] as bool? ?? false,
      wantToGoSince: parseDate(json['want_to_go_since']),
      dismissedAt: parseDate(json['dismissed_at']),
      // v1.58 (PROD-3443): the wire field is `sentiment` (was `taste`).
      taste: SignalTaste.fromWire(json['sentiment'] as String?),
      went: json['went'] as bool? ?? false,
      markedGoingAt: parseDate(json['marked_going_at']),
      goingMarksCount: (json['going_marks_count'] as num?)?.toInt() ?? 0,
      firstMarkedGoingAt: parseDate(json['first_marked_going_at']),
      source: json['source'] as String? ?? 'user',
      createdAt: parseDate(json['created_at']),
      ratedAt: parseDate(json['rated_at']),
      updatedAt: parseDate(json['updated_at']),
    );
  }
}
