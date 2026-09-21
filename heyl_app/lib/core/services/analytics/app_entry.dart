/// `app_entry` — one event per time the app comes to the front, carrying
/// which door was used. Pure Dart: no Riverpod, no PostHog, no timers of its
/// own (the scheduler is injected), so every rule is unit-testable with a
/// fake clock. Wiring lives in `app_entry_providers.dart`.
///
/// Why this exists (docs/investigations/analytics-attribution-assessment-2026-09.md,
/// Tier 2; scope review docs/investigations/context/app-entry-scope.md):
/// `app_open` fires from the auth listener before any deep link is parsed and
/// never on resume, so it cannot say where an arrival came from and misses
/// half of all foreground moments. Every major mobile SDK records the
/// foreground event with its context and applies the "is this a visit"
/// threshold in the metric, not the client (decision B2).
library;

/// The door an entry came through.
enum AppEntryType {
  icon('icon'),
  link('link'),
  push('push'),
  shareIntake('share_intake');

  const AppEntryType(this.wire);

  /// The `entry_type` property value.
  final String wire;
}

/// One emitted entry. Immutable snapshot handed to the emitter.
class AppEntry {
  const AppEntry({
    required this.entryId,
    required this.entryType,
    required this.isColdStart,
    this.backgroundSeconds,
    this.linkHost,
    this.linkPath,
    this.pushRoute,
    this.utm = const {},
  });

  /// Minted per entry; registered as a PostHog super property so every later
  /// event carries it until the next entry (join key back to the door).
  final String entryId;
  final AppEntryType entryType;
  final bool isColdStart;

  /// Seconds the app spent in the background before this resume. Null on a
  /// cold start. The "entries" metric applies its threshold to this.
  final int? backgroundSeconds;

  /// Host and path of the link that produced a `link` entry. Path only —
  /// the query string (tokens, ref codes) is never sent.
  final String? linkHost;
  final String? linkPath;

  /// The in-app route a push tap pointed at (`push` entries).
  final String? pushRoute;

  /// `utm_source` … `utm_term` of THIS entry's link. Never borrowed from the
  /// process-wide session holder (decision A6).
  final Map<String, String> utm;
}

/// Collects the doors that report in after a boot or resume and emits exactly
/// one [AppEntry] per arming, after a grace period.
class AppEntryTracker {
  AppEntryTracker({
    required this.emit,
    this.grace = const Duration(milliseconds: 1500),
    this.maxWait = const Duration(seconds: 5),
    this.doorBuffer = const Duration(seconds: 2),
    this.bareRootIsIcon = false,
    DateTime Function()? now,
    void Function(Duration delay, void Function() run)? schedule,
    required String Function() newId,
  }) : _now = now ?? DateTime.now,
       _schedule = schedule ?? _timerSchedule,
       _newId = newId;

  /// Receives the finished entry. Wired to analytics + the super property.
  final void Function(AppEntry entry) emit;

  /// How long to wait for a door to report in before classifying. All three
  /// doors deliver a fraction of a second after the app is on screen (the
  /// cold-start link in the first post-frame callback, push taps and share
  /// intents asynchronously). 1.5 s also covers the typical Short.io
  /// resolution (~300–800 ms); a slower resolve still yields a `link` entry
  /// from the short URL, just without the resolved UTMs.
  final Duration grace;

  /// Hard cap on how long a [hold] can delay the flush. Covers the slowest
  /// door sources we know of — short-link resolution (3 s budget) and the
  /// FCM initial-message check, which first waits for remote flags — with
  /// margin.
  final Duration maxWait;

  /// A door reported shortly BEFORE arming (Android delivers a warm link on
  /// `onNewIntent`, which precedes `resumed`) is kept for this long and
  /// applied to the next entry.
  final Duration doorBuffer;

  /// Web only. On web every page load reaches the app as a deep link to
  /// itself (app_links hands over the page URL), so a plain load of the
  /// site root with no attribution — someone typing the address or tapping
  /// a bookmark — would read as `link` to our own host. With this on, a
  /// link whose path is `/` (or empty) and whose query carries no
  /// `utm_*`, `ref`, `click_id` or `search` is not a door at all: the
  /// entry stays `icon`. Native keeps every link (a universal link to the
  /// bare root is still a tapped link there).
  final bool bareRootIsIcon;

  final DateTime Function() _now;
  final void Function(Duration, void Function()) _schedule;
  final String Function() _newId;

  _Pending? _pending;
  DateTime? _backgroundedAt;
  bool _booted = false;

  /// Last door reported while nothing was pending (see [doorBuffer]).
  _Pending? _bufferedDoor;
  DateTime? _bufferedAt;

  static void _timerSchedule(Duration delay, void Function() run) {
    Future<void>.delayed(delay, run);
  }

  /// Cold start. Call once, as early as possible (initState).
  void onBoot() {
    _booted = true;
    _arm(isColdStart: true, backgroundSeconds: null);
  }

  /// The app left the foreground (`paused` / `hidden`). Idempotent: the first
  /// call after a resume wins, so a paused→hidden pair records one time.
  void onBackground() {
    _backgroundedAt ??= _now();
  }

  /// The app is back on screen. Only counts when [onBackground] was seen
  /// since the last resume — an `inactive`→`resumed` blip (notification
  /// shade, system dialog) never left the foreground and is not an entry.
  void onResume() {
    final since = _backgroundedAt;
    if (since == null) return;
    _backgroundedAt = null;
    _arm(
      isColdStart: false,
      backgroundSeconds: _now().difference(since).inSeconds,
    );
  }

  /// A deep link (universal link, app link, short link, or its resolved
  /// target) was handed to the app. Last link inside the grace window wins,
  /// so a short link followed by its resolution reports the resolved UTMs.
  void noteLink(Uri uri) {
    if (bareRootIsIcon && isBareRootLink(uri)) return;
    final p = _target();
    p.type = AppEntryType.link;
    p.linkHost = uri.host.isEmpty ? null : uri.host.toLowerCase();
    p.linkPath = uri.path.isEmpty ? null : uri.path;
    p.pushRoute = null;
    p.utm = {
      for (final k in const [
        'utm_source',
        'utm_medium',
        'utm_campaign',
        'utm_content',
        'utm_term',
      ])
        if ((uri.queryParameters[k] ?? '').isNotEmpty)
          k: uri.queryParameters[k]!,
    };
  }

  /// See [bareRootIsIcon]. Bare = path `/` or empty, no fragment (a legacy
  /// hash route like `/#/lists/abc` is a real destination), and no
  /// attribution in the query: any `utm_*` key (case-insensitive), the
  /// referral/search params, or an ad click id.
  static bool isBareRootLink(Uri uri) {
    final bare = uri.path.isEmpty || uri.path == '/';
    if (!bare || uri.fragment.isNotEmpty) return false;
    const attribution = {
      'ref',
      'click_id',
      'search',
      'gclid',
      'gbraid',
      'wbraid',
      'dclid',
      'fbclid',
      'msclkid',
      'ttclid',
      'twclid',
      'igshid',
      'li_fat_id',
    };
    return !uri.queryParameters.keys.any((k) {
      final key = k.toLowerCase();
      return key.startsWith('utm_') || attribution.contains(key);
    });
  }

  /// A push notification tap opened or foregrounded the app.
  void notePush(String? route) {
    final p = _target();
    p.type = AppEntryType.push;
    p.pushRoute = route;
    p.linkHost = null;
    p.linkPath = null;
    p.utm = const {};
  }

  /// The share extension / native share intent brought the app forward.
  void noteShareIntake() {
    final p = _target();
    p.type = AppEntryType.shareIntake;
    p.linkHost = null;
    p.linkPath = null;
    p.pushRoute = null;
    p.utm = const {};
  }

  /// A door source that will report later than the grace period asks the
  /// tracker to wait: the FCM initial-message check (it waits for remote
  /// flags first) and short-link resolution (up to 3 s). The flush happens
  /// when every hold is released or at [maxWait], whichever comes first.
  /// A hold placed while nothing is pending rides the same [doorBuffer].
  void hold(Object token) => _target().holds.add(token);

  void release(Object token) {
    final p = _pending;
    if (p == null) {
      _bufferedDoor?.holds.remove(token);
      return;
    }
    p.holds.remove(token);
    if (p.graceElapsed && p.holds.isEmpty) _flush(p);
  }

  /// True while an entry is armed and waiting for its grace period.
  bool get isPending => _pending != null;

  /// The pending entry, or a short-lived buffer that the next arming will
  /// adopt (a door reported just before `resumed`). Doors are buffered ONLY
  /// while the app is backgrounded (or before boot): a door reported while
  /// foregrounded with nothing pending belongs to no entry and is dropped,
  /// so it cannot be misattributed to a later resume.
  _Pending _target() {
    final p = _pending;
    // A door that arrives while BACKGROUNDED belongs to the foregrounding
    // that is about to happen, not to a still-pending previous entry — so it
    // is buffered even when something is pending.
    if (p != null && _backgroundedAt == null) return p;
    if (_booted && _backgroundedAt == null) {
      return _Pending(isColdStart: false, backgroundSeconds: null); // dropped
    }
    final b = _bufferedDoor;
    if (b != null && _now().difference(_bufferedAt!) < doorBuffer) return b;
    final fresh = _Pending(isColdStart: false, backgroundSeconds: null);
    _bufferedDoor = fresh;
    _bufferedAt = _now();
    return fresh;
  }

  void _arm({required bool isColdStart, required int? backgroundSeconds}) {
    // Every arming is a real foregrounding (`onBoot` once, `onResume` only
    // after a real background), so a still-pending entry is a previous
    // foregrounding waiting on its grace or a slow door: flush it as-is and
    // start the new one, which keeps its own background_seconds. One
    // foregrounding, one entry — never merged, never dropped.
    final current = _pending;
    if (current != null) _flush(current);
    final p = _Pending(
      isColdStart: isColdStart,
      backgroundSeconds: backgroundSeconds,
    );
    final b = _bufferedDoor;
    if (b != null && _now().difference(_bufferedAt!) < doorBuffer) {
      p.adoptDoor(b);
    }
    _bufferedDoor = null;
    _bufferedAt = null;
    _pending = p;
    _schedule(grace, () {
      p.graceElapsed = true;
      if (p.holds.isEmpty) _flush(p);
    });
    _schedule(maxWait, () => _flush(p));
  }

  void _flush(_Pending p) {
    if (!identical(_pending, p)) return;
    _pending = null;
    emit(
      AppEntry(
        entryId: _newId(),
        entryType: p.type,
        isColdStart: p.isColdStart,
        backgroundSeconds: p.backgroundSeconds,
        linkHost: p.linkHost,
        linkPath: p.linkPath,
        pushRoute: p.pushRoute,
        utm: p.utm,
      ),
    );
  }
}

class _Pending {
  _Pending({required this.isColdStart, required this.backgroundSeconds});
  final bool isColdStart;
  final int? backgroundSeconds;
  AppEntryType type = AppEntryType.icon;
  String? linkHost;
  String? linkPath;
  String? pushRoute;
  Map<String, String> utm = const {};
  final Set<Object> holds = <Object>{};
  bool graceElapsed = false;

  void adoptDoor(_Pending other) {
    type = other.type;
    linkHost = other.linkHost;
    linkPath = other.linkPath;
    pushRoute = other.pushRoute;
    utm = other.utm;
    holds.addAll(other.holds);
  }
}

/// Remembers what a deep link pointed at, briefly, so the screen that opens
/// can say `source=deep_link` (decision B3). Replaces the process-wide
/// "has the session ever seen a UTM" flag, which mislabelled 30% of
/// `list_link_opened` rows as link opens ten minutes or more after the link.
class DeepLinkTargetLatch {
  DeepLinkTargetLatch({
    this.window = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final DateTime Function() _now;
  final Map<String, DateTime> _targets = <String, DateTime>{};

  void noteTarget(String kind, String id) {
    _targets['$kind:$id'] = _now();
  }

  bool wasTargeted(String kind, String id) {
    final at = _targets['$kind:$id'];
    return at != null && _now().difference(at) < window;
  }
}

/// The list id a deep-link route path points at (`/lists/<id>`), or null.
/// The four legacy filter sub-paths are not lists.
String? deepLinkListTargetId(String routePath) {
  final m = RegExp(r'^/lists/([^/]+)/?$').firstMatch(routePath);
  if (m == null) return null;
  final id = m.group(1)!;
  const filters = {'yours', 'soko', 'following', 'recommended'};
  return filters.contains(id) ? null : id;
}
