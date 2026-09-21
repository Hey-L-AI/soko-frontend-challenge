import '../../../core/config/environment.dart';
import '../../../l10n/generated/l10n.dart';

/// Resolve the attribution prefix to use in front of a list owner's name on
/// shelf cards.
///
/// In Portuguese (PT-PT and PT-BR) the preposition "por" contracts with a
/// feminine article into "pela". For owners that should be read as
/// feminine (currently just Soko, identified via [EnvironmentConfig.sokoHandle])
/// we use the feminine prefix; everyone else gets the article-free
/// neutral form. English is unaffected — both keys resolve to "By ".
///
/// We don't have a gender field on `user_profile` (verified
/// 2026-05-06), so this is a single-handle exception rather than a
/// general gendered-attribution feature. See D58 in
/// `docs/ui/design-decisions.md`.
String attributionPrefixFor(Lt l10n, String? ownerHandle) {
  if (ownerHandle != null && ownerHandle == EnvironmentConfig.sokoHandle) {
    return l10n.discoveryShelfFeminineAttributionPrefix;
  }
  return l10n.discoveryShelfTrendingAttributionPrefix;
}
