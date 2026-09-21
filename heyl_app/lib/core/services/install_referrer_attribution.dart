import 'dart:convert';

/// Pure parsing + classification of a Google Play Install Referrer string
/// (PROD-3478). No I/O — [AttributionService] feeds it the raw referrer and
/// the caller (app.dart) decides what to do with the result.
///
/// Referrer shapes seen in the wild:
/// - Standard UTM (our QR/van campaigns via soko.fyi/get):
///   `utm_source=Van&utm_campaign=Launch`
/// - Meta ads (Facebook/Instagram placements):
///   `utm_source=apps.facebook.com&utm_campaign=fb4a&utm_content=…` where
///   `utm_content` is url-encoded JSON of the form
///   `{"app":…,"t":…,"source":{"data":"…hex…","nonce":"…hex…"}}`.
///   The blob is ENCRYPTED (AES-256-GCM) — ad-level fields (campaign/adset/ad
///   ids) are only recoverable server-side with the decryption key from the
///   Meta App Dashboard. Client-side we detect the shape, classify the
///   channel, and keep the blob OUT of every analytics surface.
/// - Organic Play Store: empty referrer,
///   `utm_source=google-play&utm_medium=organic`, or Play's other sentinel
///   `utm_source=(not set)&utm_medium=(not set)` for store installs it could
///   not attribute. `(not set)` is dropped at parse time so it reads as an
///   absent UTM — otherwise it lands in PostHog as `acq_source='(not set)'`
///   under `acq_channel=campaign` (~480 users/month before this fix).
class InstallReferrerAttribution {
  const InstallReferrerAttribution({
    required this.rawReferrer,
    required this.acqChannel,
    required this.isMetaPaid,
    this.utmSource,
    this.utmMedium,
    this.utmCampaign,
    this.utmTerm,
    this.utmContent,
    this.referralSlug,
    this.referralClickId,
  });

  /// The referrer string exactly as Play returned it (encrypted Meta blob
  /// included). Persisted for the future backend decryption leg — never sent
  /// to PostHog.
  final String rawReferrer;

  /// Normalized acquisition channel — the single field the growth stack
  /// reads. One of [channelPaidSocial], [channelPaidOther], [channelReferral],
  /// [channelCampaign], [channelOrganicStore].
  final String acqChannel;

  /// True when the referrer matches Meta's ad-install shape.
  final bool isMetaPaid;

  final String? utmSource;
  final String? utmMedium;
  final String? utmCampaign;
  final String? utmTerm;

  /// Raw decoded `utm_content`. For Meta installs this is the multi-KB
  /// encrypted JSON blob — callers must truncate/exclude it (the touchpoint
  /// API caps it at 255 chars; PostHog never sees it at all).
  final String? utmContent;

  final String? referralSlug;
  final String? referralClickId;

  static const String channelPaidSocial = 'paid_social';
  static const String channelPaidOther = 'paid_other';
  static const String channelReferral = 'referral';
  static const String channelCampaign = 'campaign';
  static const String channelOrganicStore = 'organic_store';

  /// Whether this install carries any real attribution. Organic installs
  /// return false and never get PostHog person properties (attributed-only
  /// decision — keeps organic guests on anonymous-event pricing).
  bool get hasAttribution => acqChannel != channelOrganicStore;

  /// The `$set_once` person-property map for PostHog. Never contains the
  /// encrypted Meta blob; Meta's constant `utm_campaign=fb4a` is dropped
  /// (ad-level names arrive later via the backend decryption leg).
  Map<String, Object> get acqProps => <String, Object>{
    'acq_channel': acqChannel,
    if (utmSource != null) 'acq_source': utmSource!,
    if (utmMedium != null) 'acq_medium': utmMedium!,
    if (utmCampaign != null && !(isMetaPaid && utmCampaign == 'fb4a'))
      'acq_campaign': utmCampaign!,
  };

  /// Session UTM values safe to seed into [SessionUtmHolder] (enriches
  /// `sign_up`/`login` events). Same blob/fb4a exclusions as [acqProps].
  ///
  /// `content` is what tells our own placements apart (`ig_story`, `ig_bio`,
  /// `ig_dm`, …), so it is forwarded like the other four params — but it
  /// fails closed: nothing is forwarded for a Meta install (detected source,
  /// encrypted payload shape, OR Meta's constant `utm_campaign=fb4a`), and
  /// only a value that [isPlacementTag] accepts is forwarded at all. This is
  /// the one referrer field that has carried a multi-KB payload in the wild,
  /// and session UTMs land on PostHog events, so the filter is an allowlist
  /// rather than a length cap.
  ({
    String? source,
    String? medium,
    String? campaign,
    String? content,
    String? term,
  })
  get sessionUtm => (
    source: utmSource,
    medium: utmMedium,
    campaign: (isMetaPaid && utmCampaign == 'fb4a') ? null : utmCampaign,
    content:
        (isMetaPaid ||
            _isMetaCampaign(utmCampaign) ||
            utmContent == null ||
            !isPlacementTag(utmContent!))
        ? null
        : utmContent,
    term: utmTerm,
  );

  /// Shape of a `utm_content` value we are willing to seed into the session
  /// UTM: a short slug (`ig_story`, `link_in_bio`, a list slug, a UUID).
  /// Anything else — an email, a URL, a JSON fragment, spaces, or more than
  /// 64 chars — is not a placement tag and is dropped.
  static final RegExp _kPlacementTagPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

  static bool isPlacementTag(String value) =>
      _kPlacementTagPattern.hasMatch(value);

  /// Meta's constant install campaign name. Meta docs warn `utm_source` is
  /// not guaranteed, so this is checked independently of [isMetaPaid] before
  /// forwarding `utm_content`.
  static bool _isMetaCampaign(String? campaign) =>
      campaign?.trim().toLowerCase() == 'fb4a';

  /// Sources whose presence alone marks a Meta ad install. Meta docs warn the
  /// plain params aren't guaranteed, so [parseInstallReferrer] ALSO detects
  /// the encrypted `utm_content` shape independently.
  static const Set<String> _metaSources = {
    'apps.facebook.com',
    'apps.instagram.com',
  };

  /// Google Play's placeholder for a UTM it has no value for
  /// (`utm_source=(not set)&utm_medium=(not set)` on unattributed installs).
  /// Same meaning as the key being absent; never a real campaign value.
  /// Compared case-insensitively after trimming, so `(NOT SET)` or a
  /// value with stray whitespace is dropped too.
  static const String _kPlayNotSet = '(not set)';

  static bool _isPlayNotSet(String value) =>
      value.trim().toLowerCase() == _kPlayNotSet;

  /// Mediums that mean "paid" for non-Meta campaigns.
  static const Set<String> _paidMediums = {
    'cpc',
    'ppc',
    'paid',
    'paid_social',
    'paid_search',
    'display',
  };

  static InstallReferrerAttribution parse(String referrer) {
    final params = _parseQueryString(referrer);

    final utmSource = params['utm_source'];
    final utmMedium = params['utm_medium'];
    final utmCampaign = params['utm_campaign'];
    final utmTerm = params['utm_term'];
    final utmContent = params['utm_content'];
    final referralSlug = params['ref'];
    final referralClickId = params['click_id'];

    final isMetaPaid =
        (utmSource != null &&
            _metaSources.contains(utmSource.trim().toLowerCase())) ||
        _looksLikeMetaEncryptedPayload(utmContent);

    final String acqChannel;
    if (isMetaPaid) {
      acqChannel = channelPaidSocial;
    } else if (referralSlug != null || referralClickId != null) {
      acqChannel = channelReferral;
    } else if (utmMedium != null &&
        _paidMediums.contains(utmMedium.toLowerCase())) {
      acqChannel = channelPaidOther;
    } else if (utmMedium?.toLowerCase() == 'organic' ||
        (utmSource == null && utmCampaign == null)) {
      // `utm_source=google-play&utm_medium=organic` is Play's own stamp for
      // an unattributed store install — same bucket as an empty referrer.
      acqChannel = channelOrganicStore;
    } else {
      // Owned-marketing UTMs (QR codes, vans, newsletters, …).
      acqChannel = channelCampaign;
    }

    return InstallReferrerAttribution(
      rawReferrer: referrer,
      acqChannel: acqChannel,
      isMetaPaid: isMetaPaid,
      utmSource: utmSource,
      utmMedium: utmMedium,
      utmCampaign: utmCampaign,
      utmTerm: utmTerm,
      utmContent: utmContent,
      referralSlug: referralSlug,
      referralClickId: referralClickId,
    );
  }

  /// Manual query-string parse. `Uri.parse('https://x/?$referrer')` is NOT
  /// safe here: Meta's `utm_content` value contains `=`/`&`-adjacent
  /// percent-encoding that a full-URI round-trip can mangle. Splitting on
  /// `&` then on the FIRST `=` and decoding each component independently
  /// keeps arbitrary values intact. First occurrence of a key wins.
  /// Values matching [_kPlayNotSet] are dropped as if the key were absent.
  static Map<String, String> _parseQueryString(String referrer) {
    final result = <String, String>{};
    for (final pair in referrer.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final rawKey = pair.substring(0, eq);
      final rawValue = pair.substring(eq + 1);
      try {
        final key = Uri.decodeQueryComponent(rawKey);
        final value = Uri.decodeQueryComponent(rawValue);
        if (value.isEmpty || _isPlayNotSet(value)) continue;
        result.putIfAbsent(key, () => value);
      } catch (_) {
        // Malformed percent-encoding — skip the pair, keep the rest.
      }
    }
    return result;
  }

  /// Detects Meta's encrypted install-referrer payload:
  /// `{"app":<id>,"t":<ts>,"source":{"data":"<hex>","nonce":"<hex>"}}`.
  static bool _looksLikeMetaEncryptedPayload(String? utmContent) {
    if (utmContent == null || !utmContent.trimLeft().startsWith('{')) {
      return false;
    }
    try {
      final decoded = jsonDecode(utmContent);
      if (decoded is! Map<String, dynamic>) return false;
      final source = decoded['source'];
      return source is Map<String, dynamic> && source['data'] is String;
    } catch (_) {
      return false;
    }
  }
}
