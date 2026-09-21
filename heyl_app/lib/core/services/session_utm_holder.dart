import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the UTM parameters for the current session.
///
/// Populated when the app opens via a deep link with UTM params.
/// Read by [UnifiedAnalyticsService._dispatch] to auto-merge UTM
/// properties into whitelisted analytics events.
///
/// Not a StateNotifier — no UI rebuilds needed. Just a mutable holder
/// that lives for the session lifetime.
class SessionUtmHolder {
  Map<String, String>? _current;
  String? _referrer;

  /// Current session UTM params (null if no UTMs in this session).
  Map<String, String>? get current => _current;

  /// The document.referrer captured on web (null on native or if empty).
  String? get referrer => _referrer;

  /// Whether this session has any campaign attribution data.
  bool get hasAttribution => _current != null || (_referrer != null && _referrer!.isNotEmpty);

  /// Store UTM params from a deep link or URL.
  ///
  /// Overwrites any previous session UTM (latest link wins).
  void setUtm({
    String? utmSource,
    String? utmMedium,
    String? utmCampaign,
    String? utmContent,
    String? utmTerm,
  }) {
    final hasAny = utmSource != null ||
        utmMedium != null ||
        utmCampaign != null ||
        utmContent != null ||
        utmTerm != null;

    if (!hasAny) return;

    _current = {
      if (utmSource != null) 'utm_source': utmSource,
      if (utmMedium != null) 'utm_medium': utmMedium,
      if (utmCampaign != null) 'utm_campaign': utmCampaign,
      if (utmContent != null) 'utm_content': utmContent,
      if (utmTerm != null) 'utm_term': utmTerm,
    };
  }

  /// Store the document.referrer from web.
  void setReferrer(String? referrer) {
    if (referrer != null && referrer.isNotEmpty) {
      _referrer = referrer;
    }
  }

  /// Clear all session attribution (e.g., on logout or new session).
  void clear() {
    _current = null;
    _referrer = null;
  }
}

/// Singleton session UTM holder — lives for the app process lifetime.
final sessionUtmHolderProvider = Provider<SessionUtmHolder>((ref) {
  return SessionUtmHolder();
});
