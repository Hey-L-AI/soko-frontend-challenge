import 'package:flutter/widgets.dart';

import '../../../l10n/generated/l10n.dart';
import 'memory_hierarchy.dart' show subcategoryGroupCategoryKey;

/// Render a taxonomy value as the user-facing string for the Memory page.
///
/// Lookup order (per family):
///   1. Curated locale-aware label in [_displayLabels] for the active
///      locale. Returns "Esplanada" / "Outdoor seating" — copy chosen to
///      read naturally, not literal translations.
///   2. Curated label fallback to the canonical English entry.
///   3. Mechanical humanisation — strip parent prefix for
///      `event_sub_categories`, replace `_`/`-` with spaces, sentence-case
///      the first letter.
///
/// The function is pure: pass the family key (e.g. `'cuisine'`,
/// `'amenities'`) and the canonical value (`'italian'`,
/// `'outdoor_seating'`). Locale is derived from the current context — pass
/// `localeOverride` for tests.
String humanizeMemoryValue(
  BuildContext context,
  String value, {
  String? family,
  String? localeOverride,
}) {
  if (value.isEmpty) return value;

  final locale = localeOverride ?? Localizations.localeOf(context).toString();
  final localeKey = _normaliseLocaleKey(locale);

  if (family != null) {
    // PROD-3766: an ambiguous sub-category tail ("art-workshop" vs
    // "education-workshop" both read "Workshop") composes with its parent
    // category so the chip says which workshop it is.
    if (family == 'event_sub_categories') {
      final composed = _composeAmbiguousSubcategory(value, localeKey);
      if (composed != null) return composed;
    }
    final familyMap = _displayLabels[family];
    if (familyMap != null) {
      final entry = familyMap[value.toLowerCase()];
      if (entry != null) {
        // Prefer requested locale, fall back to en.
        final localised = entry[localeKey] ?? entry['en'];
        if (localised != null && localised.isNotEmpty) return localised;
      }
    }
    if (family == 'venue_types') {
      // 2026-09-09: ~120 of the 406 venue types are `<adjective>_restaurant`
      // — compose "Restaurante brasileiro" from the adjective map instead of
      // curating each one. EN keeps the mechanical form.
      final composedRestaurant = _venueRestaurantLabel(value, localeKey);
      if (composedRestaurant != null) return composedRestaurant;
    }
  }

  return _mechanicalHumanise(value, family: family);
}

/// "brazilian_restaurant" → "Restaurante brasileiro" (pt-PT/pt-BR) via the
/// adjective map. Returns null for EN (mechanical is already right), for
/// non-restaurant slugs, and for adjectives the map doesn't know.
String? _venueRestaurantLabel(String value, String localeKey) {
  if (localeKey == 'en') return null;
  final v = value.toLowerCase();
  if (!v.endsWith('_restaurant')) return null;
  final adj = _restaurantAdjectives[v.substring(0, v.length - 11)];
  if (adj == null) return null;
  final word = adj[localeKey] ?? adj['pt-PT'];
  if (word == null) return null;
  return 'Restaurante $word';
}

/// Adjective (or qualifying phrase) that follows "Restaurante " for the
/// `<x>_restaurant` venue types. Keys without an entry fall back to the
/// mechanical English label. Idiomatic non-adjective venues (marisqueira,
/// churrascaria…) live in the curated map instead.
const Map<String, Map<String, String>> _restaurantAdjectives = {
  'afghani': {'pt-PT': 'afegão'},
  'african': {'pt-PT': 'africano'},
  'american': {'pt-PT': 'americano'},
  'angolan': {'pt-PT': 'angolano'},
  'argentinian': {'pt-PT': 'argentino'},
  'asian': {'pt-PT': 'asiático'},
  'asian_fusion': {'pt-PT': 'de fusão asiática'},
  'australian': {'pt-PT': 'australiano'},
  'austrian': {'pt-PT': 'austríaco'},
  'bangladeshi': {'pt-PT': 'do Bangladesh'},
  'basque': {'pt-PT': 'basco'},
  'bavarian': {'pt-PT': 'bávaro'},
  'beach': {'pt-PT': 'de praia'},
  'belgian': {'pt-PT': 'belga'},
  'brazilian': {'pt-PT': 'brasileiro'},
  'british': {'pt-PT': 'britânico'},
  'brunch': {'pt-PT': 'de brunch'},
  'burmese': {'pt-PT': 'birmanês'},
  'californian': {'pt-PT': 'californiano'},
  'cajun': {'pt-PT': 'cajun'},
  'cambodian': {'pt-PT': 'cambojano'},
  'cantonese': {'pt-PT': 'cantonês'},
  'caribbean': {'pt-PT': 'caribenho'},
  'chilean': {'pt-PT': 'chileno'},
  'chinese': {'pt-PT': 'chinês'},
  'colombian': {'pt-PT': 'colombiano'},
  'croatian': {'pt-PT': 'croata'},
  'cuban': {'pt-PT': 'cubano'},
  'czech': {'pt-PT': 'checo', 'pt-BR': 'tcheco'},
  'danish': {'pt-PT': 'dinamarquês'},
  'dutch': {'pt-PT': 'holandês'},
  'eastern_european': {'pt-PT': 'do Leste Europeu'},
  'ethiopian': {'pt-PT': 'etíope'},
  'european': {'pt-PT': 'europeu'},
  'family': {'pt-PT': 'familiar'},
  'filipino': {'pt-PT': 'filipino'},
  'fine_dining': {'pt-PT': 'gourmet'},
  'french': {'pt-PT': 'francês'},
  'fusion': {'pt-PT': 'de fusão'},
  'german': {'pt-PT': 'alemão'},
  'gluten_free': {'pt-PT': 'sem glúten'},
  'greek': {'pt-PT': 'grego'},
  'halal': {'pt-PT': 'halal'},
  'hawaiian': {'pt-PT': 'havaiano'},
  'healthy': {'pt-PT': 'saudável'},
  'hungarian': {'pt-PT': 'húngaro'},
  'indian': {'pt-PT': 'indiano'},
  'indonesian': {'pt-PT': 'indonésio'},
  'irish': {'pt-PT': 'irlandês'},
  'israeli': {'pt-PT': 'israelita', 'pt-BR': 'israelense'},
  'italian': {'pt-PT': 'italiano'},
  'japanese': {'pt-PT': 'japonês'},
  'korean': {'pt-PT': 'coreano'},
  'latin_american': {'pt-PT': 'latino-americano'},
  'lebanese': {'pt-PT': 'libanês'},
  'malaysian': {'pt-PT': 'malaio'},
  'mediterranean': {'pt-PT': 'mediterrânico', 'pt-BR': 'mediterrâneo'},
  'mexican': {'pt-PT': 'mexicano'},
  'middle_eastern': {'pt-PT': 'do Médio Oriente', 'pt-BR': 'do Oriente Médio'},
  'mongolian_barbecue': {'pt-PT': 'de churrasco mongol'},
  'moroccan': {'pt-PT': 'marroquino'},
  'mozambican': {'pt-PT': 'moçambicano'},
  'north_indian': {'pt-PT': 'do Norte da Índia'},
  'pakistani': {'pt-PT': 'paquistanês'},
  'persian': {'pt-PT': 'persa'},
  'peruvian': {'pt-PT': 'peruano'},
  'polish': {'pt-PT': 'polaco', 'pt-BR': 'polonês'},
  'pop_up': {'pt-PT': 'pop-up'},
  'portuguese': {'pt-PT': 'português'},
  'romanian': {'pt-PT': 'romeno'},
  'rooftop': {'pt-PT': 'rooftop'},
  'russian': {'pt-PT': 'russo'},
  'scandinavian': {'pt-PT': 'escandinavo'},
  'soul_food': {'pt-PT': 'de soul food'},
  'south_american': {'pt-PT': 'sul-americano'},
  'south_indian': {'pt-PT': 'do Sul da Índia'},
  'spanish': {'pt-PT': 'espanhol'},
  'swiss': {'pt-PT': 'suíço'},
  'taiwanese': {'pt-PT': 'taiwanês'},
  'thai': {'pt-PT': 'tailandês'},
  'tibetan': {'pt-PT': 'tibetano'},
  'turkish': {'pt-PT': 'turco'},
  'typical': {'pt-PT': 'típico'},
  'ukrainian': {'pt-PT': 'ucraniano'},
  'vegan': {'pt-PT': 'vegan', 'pt-BR': 'vegano'},
  'vegetarian': {'pt-PT': 'vegetariano'},
  'vietnamese': {'pt-PT': 'vietnamita'},
};

/// Sub-category tails that mean nothing without their category ("Workshop",
/// "Festival", "Activity", …). Derived from the curated sub-category label
/// map (a tail under 2+ prefixes is ambiguous) plus a curated set of
/// generic tails for slugs the map doesn't list.
final Set<String> _ambiguousSubTails = _buildAmbiguousSubTails();

const Set<String> _genericSubTails = {
  'activity',
  'class',
  'festival',
  'market',
  'night',
  'party',
  'performance',
  'show',
  'tour',
  'workshop',
  // NOT 'live' / 'dj': unique to music-*, and their curated labels
  // ("Live music", "DJ set") already carry the meaning.
};

Set<String> _buildAmbiguousSubTails() {
  final byTail = <String, Set<String>>{};
  for (final slug
      in (_displayLabels['event_sub_categories'] ?? const {}).keys) {
    final dash = slug.indexOf('-');
    if (dash <= 0) continue;
    byTail
        .putIfAbsent(slug.substring(dash + 1), () => <String>{})
        .add(slug.substring(0, dash));
  }
  return {
    ..._genericSubTails,
    for (final e in byTail.entries)
      if (e.value.length > 1) e.key,
  };
}

/// "art-workshop" → "Art workshop" / "Workshop de arte" when the tail is
/// ambiguous; null otherwise (normal label flow applies).
String? _composeAmbiguousSubcategory(String value, String localeKey) {
  final slug = value.toLowerCase();
  final dash = slug.indexOf('-');
  if (dash <= 0) return null;
  final prefix = slug.substring(0, dash);
  final tail = slug.substring(dash + 1);
  if (!_ambiguousSubTails.contains(tail)) return null;

  // Sub label: curated entry if any, else mechanical tail.
  final subEntry = _displayLabels['event_sub_categories']?[slug];
  var sub = subEntry?[localeKey] ?? subEntry?['en'];
  if (sub == null || sub.isEmpty) {
    final cleanTail = tail.replaceAll('-', ' ').replaceAll('_', ' ').trim();
    if (cleanTail.isEmpty) return null;
    sub = cleanTail[0].toUpperCase() + cleanTail.substring(1);
  }

  // Category label via the grouping key (multi-word categories keep their
  // full display key: education → "education & talks").
  final categoryKey = subcategoryGroupCategoryKey(prefix);
  final catEntry = _displayLabels['event_categories']?[categoryKey];
  var category = catEntry?[localeKey] ?? catEntry?['en'];
  category ??= prefix[0].toUpperCase() + prefix.substring(1);

  if (localeKey == 'en') {
    return '$category ${sub[0].toLowerCase()}${sub.substring(1)}';
  }
  return '$sub de ${category[0].toLowerCase()}${category.substring(1)}';
}

/// Maps a Flutter locale like `pt_PT` or `pt-BR` to one of our canonical
/// keys: `en`, `pt-PT`, `pt-BR`. Unknown locales fall back to `en`.
String _normaliseLocaleKey(String locale) {
  final normalised = locale.replaceAll('_', '-');
  if (normalised.startsWith('pt-BR')) return 'pt-BR';
  if (normalised.startsWith('pt')) return 'pt-PT';
  return 'en';
}

String _mechanicalHumanise(String value, {String? family}) {
  if (value.isEmpty) return value;

  var clean = value;
  // Strip the parent prefix for event_sub_categories: "culture-comedy" →
  // "comedy" (the parent category is already shown elsewhere).
  if (family == 'event_sub_categories' && clean.contains('-')) {
    final parts = clean.split('-');
    if (parts.length > 1) {
      clean = parts.skip(1).join(' ');
    }
  }
  clean = clean.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  if (clean.isEmpty) return value;
  return clean[0].toUpperCase() + clean.substring(1);
}

/// Curated display labels per family + locale. PT-PT chosen first
/// (Soko's primary audience), EN is the canonical fallback, PT-BR added
/// where the wording differs meaningfully. Values not listed here cascade
/// to the mechanical fallback — coverage is intentionally for the
/// most-frequent values, not exhaustive.
const Map<String, Map<String, Map<String, String>>> _displayLabels = {
  // PROD-2799: cuisine chips read as "Italian food" / "Comida italiana" so a
  // bare nationality ("Italian") isn't ambiguous on the Tastes surface. PT
  // agrees in gender with the feminine "comida". Dish-type cuisines (seafood,
  // sushi, pizza, burgers) are already unambiguous and keep their plain label.
  'cuisine': {
    'italian': {
      'en': 'Italian food',
      'pt-PT': 'Comida italiana',
      'pt-BR': 'Comida italiana',
    },
    'japanese': {
      'en': 'Japanese food',
      'pt-PT': 'Comida japonesa',
      'pt-BR': 'Comida japonesa',
    },
    'portuguese': {
      'en': 'Portuguese food',
      'pt-PT': 'Comida portuguesa',
      'pt-BR': 'Comida portuguesa',
    },
    'french': {
      'en': 'French food',
      'pt-PT': 'Comida francesa',
      'pt-BR': 'Comida francesa',
    },
    'spanish': {
      'en': 'Spanish food',
      'pt-PT': 'Comida espanhola',
      'pt-BR': 'Comida espanhola',
    },
    'mexican': {
      'en': 'Mexican food',
      'pt-PT': 'Comida mexicana',
      'pt-BR': 'Comida mexicana',
    },
    'chinese': {
      'en': 'Chinese food',
      'pt-PT': 'Comida chinesa',
      'pt-BR': 'Comida chinesa',
    },
    'indian': {
      'en': 'Indian food',
      'pt-PT': 'Comida indiana',
      'pt-BR': 'Comida indiana',
    },
    'thai': {
      'en': 'Thai food',
      'pt-PT': 'Comida tailandesa',
      'pt-BR': 'Comida tailandesa',
    },
    'vietnamese': {
      'en': 'Vietnamese food',
      'pt-PT': 'Comida vietnamita',
      'pt-BR': 'Comida vietnamita',
    },
    'korean': {
      'en': 'Korean food',
      'pt-PT': 'Comida coreana',
      'pt-BR': 'Comida coreana',
    },
    'asian': {
      'en': 'Asian food',
      'pt-PT': 'Comida asiática',
      'pt-BR': 'Comida asiática',
    },
    'mediterranean': {
      'en': 'Mediterranean food',
      'pt-PT': 'Comida mediterrânica',
      'pt-BR': 'Comida mediterrânea',
    },
    'lebanese': {
      'en': 'Lebanese food',
      'pt-PT': 'Comida libanesa',
      'pt-BR': 'Comida libanesa',
    },
    'brazilian': {
      'en': 'Brazilian food',
      'pt-PT': 'Comida brasileira',
      'pt-BR': 'Comida brasileira',
    },
    'african': {
      'en': 'African food',
      'pt-PT': 'Comida africana',
      'pt-BR': 'Comida africana',
    },
    'fusion': {
      'en': 'Fusion food',
      'pt-PT': 'Comida de fusão',
      'pt-BR': 'Comida de fusão',
    },
    'seafood': {'en': 'Seafood', 'pt-PT': 'Marisco', 'pt-BR': 'Frutos do mar'},
    'sushi': {'en': 'Sushi', 'pt-PT': 'Sushi', 'pt-BR': 'Sushi'},
    'pizza': {'en': 'Pizza', 'pt-PT': 'Pizza', 'pt-BR': 'Pizza'},
    'burger': {
      'en': 'Burgers',
      'pt-PT': 'Hambúrgueres',
      'pt-BR': 'Hambúrgueres',
    },
    'vegan': {
      'en': 'Vegan food',
      'pt-PT': 'Comida vegana',
      'pt-BR': 'Comida vegana',
    },
    'vegetarian': {
      'en': 'Vegetarian food',
      'pt-PT': 'Comida vegetariana',
      'pt-BR': 'Comida vegetariana',
    },
  },
  'dietary': {
    'vegetarian': {
      'en': 'Vegetarian',
      'pt-PT': 'Vegetariano',
      'pt-BR': 'Vegetariano',
    },
    'vegan': {'en': 'Vegan', 'pt-PT': 'Vegan', 'pt-BR': 'Vegano'},
    'gluten_free': {
      'en': 'Gluten-free',
      'pt-PT': 'Sem glúten',
      'pt-BR': 'Sem glúten',
    },
    'celiac': {'en': 'Coeliac', 'pt-PT': 'Celíaco', 'pt-BR': 'Celíaco'},
    'lactose_free': {
      'en': 'Lactose-free',
      'pt-PT': 'Sem lactose',
      'pt-BR': 'Sem lactose',
    },
    'dairy_free': {
      'en': 'Dairy-free',
      'pt-PT': 'Sem lacticínios',
      'pt-BR': 'Sem laticínios',
    },
    'halal': {'en': 'Halal', 'pt-PT': 'Halal', 'pt-BR': 'Halal'},
    'kosher': {'en': 'Kosher', 'pt-PT': 'Kosher', 'pt-BR': 'Kosher'},
    'pescatarian': {
      'en': 'Pescatarian',
      'pt-PT': 'Pescetariano',
      'pt-BR': 'Pescetariano',
    },
    'nut_free': {
      'en': 'Nut-free',
      'pt-PT': 'Sem frutos secos',
      'pt-BR': 'Sem castanhas',
    },
  },
  'vibes': {
    'cozy': {'en': 'Cosy', 'pt-PT': 'Acolhedor', 'pt-BR': 'Aconchegante'},
    'lively': {'en': 'Lively', 'pt-PT': 'Animado', 'pt-BR': 'Animado'},
    'romantic': {'en': 'Romantic', 'pt-PT': 'Romântico', 'pt-BR': 'Romântico'},
    'intimate': {'en': 'Intimate', 'pt-PT': 'Íntimo', 'pt-BR': 'Íntimo'},
    'energetic': {
      'en': 'Energetic',
      'pt-PT': 'Energético',
      'pt-BR': 'Energético',
    },
    'chill': {'en': 'Chill', 'pt-PT': 'Tranquilo', 'pt-BR': 'Tranquilo'},
    'quiet': {'en': 'Quiet', 'pt-PT': 'Silencioso', 'pt-BR': 'Silencioso'},
    'festive': {'en': 'Festive', 'pt-PT': 'Festivo', 'pt-BR': 'Festivo'},
    'fun': {'en': 'Fun', 'pt-PT': 'Divertido', 'pt-BR': 'Divertido'},
    'trendy': {'en': 'Trendy', 'pt-PT': 'Moderno', 'pt-BR': 'Descolado'},
    'hipster': {'en': 'Hipster', 'pt-PT': 'Hipster', 'pt-BR': 'Hipster'},
    'underground': {
      'en': 'Underground',
      'pt-PT': 'Underground',
      'pt-BR': 'Underground',
    },
    'alternative': {
      'en': 'Alternative',
      'pt-PT': 'Alternativo',
      'pt-BR': 'Alternativo',
    },
    'bohemian': {'en': 'Bohemian', 'pt-PT': 'Boémio', 'pt-BR': 'Boêmio'},
    'modern': {'en': 'Modern', 'pt-PT': 'Moderno', 'pt-BR': 'Moderno'},
    'retro': {'en': 'Retro', 'pt-PT': 'Retro', 'pt-BR': 'Retrô'},
    'minimalist': {
      'en': 'Minimalist',
      'pt-PT': 'Minimalista',
      'pt-BR': 'Minimalista',
    },
    'industrial': {
      'en': 'Industrial',
      'pt-PT': 'Industrial',
      'pt-BR': 'Industrial',
    },
    'rustic': {'en': 'Rustic', 'pt-PT': 'Rústico', 'pt-BR': 'Rústico'},
    'traditional': {
      'en': 'Traditional',
      'pt-PT': 'Tradicional',
      'pt-BR': 'Tradicional',
    },
    'casual': {'en': 'Casual', 'pt-PT': 'Descontraído', 'pt-BR': 'Casual'},
    'upscale': {
      'en': 'Upscale',
      'pt-PT': 'Sofisticado',
      'pt-BR': 'Sofisticado',
    },
    'luxury': {'en': 'Luxury', 'pt-PT': 'Luxuoso', 'pt-BR': 'Luxuoso'},
    'eclectic': {'en': 'Eclectic', 'pt-PT': 'Eclético', 'pt-BR': 'Eclético'},
    'artistic': {'en': 'Artistic', 'pt-PT': 'Artístico', 'pt-BR': 'Artístico'},
    'creative': {'en': 'Creative', 'pt-PT': 'Criativo', 'pt-BR': 'Criativo'},
    'cultural': {'en': 'Cultural', 'pt-PT': 'Cultural', 'pt-BR': 'Cultural'},
    'authentic': {
      'en': 'Authentic',
      'pt-PT': 'Autêntico',
      'pt-BR': 'Autêntico',
    },
    'sophisticated': {
      'en': 'Sophisticated',
      'pt-PT': 'Sofisticado',
      'pt-BR': 'Sofisticado',
    },
    'scenic': {'en': 'Scenic', 'pt-PT': 'Pitoresco', 'pt-BR': 'Cênico'},
    'adventurous': {
      'en': 'Adventurous',
      'pt-PT': 'Aventureiro',
      'pt-BR': 'Aventureiro',
    },
    'sporty': {'en': 'Sporty', 'pt-PT': 'Desportivo', 'pt-BR': 'Esportivo'},
    'original': {'en': 'Original', 'pt-PT': 'Original', 'pt-BR': 'Original'},
    'curated': {'en': 'Curated', 'pt-PT': 'Curado', 'pt-BR': 'Curado'},
    'sustainable': {
      'en': 'Sustainable',
      'pt-PT': 'Sustentável',
      'pt-BR': 'Sustentável',
    },
    'inclusive': {
      'en': 'Inclusive',
      'pt-PT': 'Inclusivo',
      'pt-BR': 'Inclusivo',
    },
    'community_driven': {
      'en': 'Community-driven',
      'pt-PT': 'Comunitário',
      'pt-BR': 'Comunitário',
    },
    'family_friendly': {
      'en': 'Family-friendly',
      'pt-PT': 'Para a família',
      'pt-BR': 'Para a família',
    },
    'wellness_focused': {
      'en': 'Wellness',
      'pt-PT': 'Bem-estar',
      'pt-BR': 'Bem-estar',
    },
    'spiritual': {
      'en': 'Spiritual',
      'pt-PT': 'Espiritual',
      'pt-BR': 'Espiritual',
    },
    'hidden_gem': {
      'en': 'Hidden gem',
      'pt-PT': 'Joia escondida',
      'pt-BR': 'Joia escondida',
    },
    'local_gem': {
      'en': 'Local gem',
      'pt-PT': 'Joia local',
      'pt-BR': 'Joia local',
    },
    'nostalgic': {
      'en': 'Nostalgic',
      'pt-PT': 'Nostálgico',
      'pt-BR': 'Nostálgico',
    },
    'instagrammable': {
      'en': 'Instagrammable',
      'pt-PT': 'Instagramável',
      'pt-BR': 'Instagramável',
    },
    'touristy': {'en': 'Touristy', 'pt-PT': 'Turístico', 'pt-BR': 'Turístico'},
    'mainstream': {
      'en': 'Mainstream',
      'pt-PT': 'Convencional',
      'pt-BR': 'Mainstream',
    },
    'niche': {'en': 'Niche', 'pt-PT': 'Nicho', 'pt-BR': 'Nicho'},
    'exclusive': {
      'en': 'Exclusive',
      'pt-PT': 'Exclusivo',
      'pt-BR': 'Exclusivo',
    },
    'heritage': {
      'en': 'Heritage',
      'pt-PT': 'Património',
      'pt-BR': 'Patrimônio',
    },
    'indie': {'en': 'Indie', 'pt-PT': 'Indie', 'pt-BR': 'Indie'},
    'emerging': {'en': 'Emerging', 'pt-PT': 'Emergente', 'pt-BR': 'Emergente'},
    'hyper_local': {
      'en': 'Hyper-local',
      'pt-PT': 'Bem local',
      'pt-BR': 'Bem local',
    },
    'nomadic': {'en': 'Nomadic', 'pt-PT': 'Nómada', 'pt-BR': 'Nômade'},
    'progressive': {
      'en': 'Progressive',
      'pt-PT': 'Progressista',
      'pt-BR': 'Progressista',
    },
    'eco_conscious': {
      'en': 'Eco-conscious',
      'pt-PT': 'Ecológico',
      'pt-BR': 'Ecológico',
    },
    'intense': {'en': 'Intense', 'pt-PT': 'Intenso', 'pt-BR': 'Intenso'},
    'recommended': {
      'en': 'Recommended',
      'pt-PT': 'Recomendado',
      'pt-BR': 'Recomendado',
    },
  },
  'amenities': {
    'outdoor_seating': {
      'en': 'Outdoor seating',
      'pt-PT': 'Esplanada',
      'pt-BR': 'Mesas ao ar livre',
    },
    'live_music': {
      'en': 'Live music',
      'pt-PT': 'Música ao vivo',
      'pt-BR': 'Música ao vivo',
    },
    'wifi': {'en': 'Wi-Fi', 'pt-PT': 'Wi-Fi', 'pt-BR': 'Wi-Fi'},
    'allows_dogs': {
      'en': 'Dog-friendly',
      'pt-PT': 'Aceita cães',
      'pt-BR': 'Aceita cães',
    },
    'pet_friendly': {
      'en': 'Pet-friendly',
      'pt-PT': 'Pet-friendly',
      'pt-BR': 'Pet-friendly',
    },
    'wheelchair_accessible': {
      'en': 'Wheelchair accessible',
      'pt-PT': 'Acessível a cadeiras de rodas',
      'pt-BR': 'Acessível para cadeirantes',
    },
    'parking': {
      'en': 'Parking',
      'pt-PT': 'Estacionamento',
      'pt-BR': 'Estacionamento',
    },
    'rooftop': {'en': 'Rooftop', 'pt-PT': 'Rooftop', 'pt-BR': 'Cobertura'},
    'garden': {'en': 'Garden', 'pt-PT': 'Jardim', 'pt-BR': 'Jardim'},
    'fireplace': {'en': 'Fireplace', 'pt-PT': 'Lareira', 'pt-BR': 'Lareira'},
    'view': {'en': 'Great view', 'pt-PT': 'Bela vista', 'pt-BR': 'Bela vista'},
  },
  'meal_periods': {
    'breakfast': {
      'en': 'Breakfast',
      'pt-PT': 'Pequeno-almoço',
      'pt-BR': 'Café da manhã',
    },
    'brunch': {'en': 'Brunch', 'pt-PT': 'Brunch', 'pt-BR': 'Brunch'},
    'lunch': {'en': 'Lunch', 'pt-PT': 'Almoço', 'pt-BR': 'Almoço'},
    'dinner': {'en': 'Dinner', 'pt-PT': 'Jantar', 'pt-BR': 'Jantar'},
    'late_night': {
      'en': 'Late night',
      'pt-PT': 'Madrugada',
      'pt-BR': 'Madrugada',
    },
  },
  'occasions': {
    'with_friends': {
      'en': 'With friends',
      'pt-PT': 'Com amigos',
      'pt-BR': 'Com amigos',
    },
    'family': {'en': 'Family', 'pt-PT': 'Família', 'pt-BR': 'Família'},
    'family_meal': {
      'en': 'Family meal',
      'pt-PT': 'Refeição em família',
      'pt-BR': 'Refeição em família',
    },
    'work': {'en': 'Work', 'pt-PT': 'Trabalho', 'pt-BR': 'Trabalho'},
    'celebration': {
      'en': 'Celebration',
      'pt-PT': 'Celebração',
      'pt-BR': 'Celebração',
    },
    'solo': {'en': 'Solo', 'pt-PT': 'Sozinho', 'pt-BR': 'Sozinho'},
    'drinks': {'en': 'Drinks', 'pt-PT': 'Para beber algo', 'pt-BR': 'Drinks'},
    'casual_hangout': {
      'en': 'Casual hangout',
      'pt-PT': 'Convívio casual',
      'pt-BR': 'Encontro casual',
    },
    'group_outing': {
      'en': 'Group outing',
      'pt-PT': 'Saída em grupo',
      'pt-BR': 'Saída em grupo',
    },
    'date': {
      'en': 'Date',
      'pt-PT': 'Encontro romântico',
      'pt-BR': 'Encontro romântico',
    },
  },
  'quality_bars': {
    'top_rated': {
      'en': 'Top-rated',
      'pt-PT': 'Melhor avaliado',
      'pt-BR': 'Melhor avaliado',
    },
    'premium': {'en': 'Premium', 'pt-PT': 'Premium', 'pt-BR': 'Premium'},
    'hidden_gem': {
      'en': 'Hidden gem',
      'pt-PT': 'Joia escondida',
      'pt-BR': 'Joia escondida',
    },
    'recommended': {
      'en': 'Recommended',
      'pt-PT': 'Recomendado',
      'pt-BR': 'Recomendado',
    },
    'michelin': {'en': 'Michelin', 'pt-PT': 'Michelin', 'pt-BR': 'Michelin'},
  },
  'service_formats': {
    'reservable': {
      'en': 'Takes reservations',
      'pt-PT': 'Aceita reservas',
      'pt-BR': 'Aceita reservas',
    },
    'takeout': {'en': 'Takeaway', 'pt-PT': 'Take-away', 'pt-BR': 'Para viagem'},
    'delivery': {'en': 'Delivery', 'pt-PT': 'Entrega', 'pt-BR': 'Delivery'},
    'tasting_menu': {
      'en': 'Tasting menu',
      'pt-PT': 'Menu de degustação',
      'pt-BR': 'Menu degustação',
    },
  },
  'venue_types': {
    // 2026-09-09: common venue chips authored in PT (EN keeps mechanical);
    // idiomatic PT nouns (marisqueira, churrascaria, gelataria…) live here,
    // nationality restaurants compose via _restaurantAdjectives.
    'seafood_restaurant': {
      'en': 'Seafood restaurant',
      'pt-PT': 'Marisqueira',
      'pt-BR': 'Restaurante de frutos do mar',
    },
    'barbecue_restaurant': {
      'en': 'Barbecue restaurant',
      'pt-PT': 'Churrascaria',
      'pt-BR': 'Churrascaria',
    },
    'hamburger_restaurant': {
      'en': 'Burger joint',
      'pt-PT': 'Hamburgueria',
      'pt-BR': 'Hamburgueria',
    },
    'sushi_restaurant': {
      'en': 'Sushi restaurant',
      'pt-PT': 'Restaurante de sushi',
      'pt-BR': 'Restaurante de sushi',
    },
    'ramen_restaurant': {
      'en': 'Ramen restaurant',
      'pt-PT': 'Restaurante de ramen',
      'pt-BR': 'Restaurante de ramen',
    },
    'tapas_restaurant': {
      'en': 'Tapas restaurant',
      'pt-PT': 'Restaurante de tapas',
      'pt-BR': 'Restaurante de tapas',
    },
    'fast_food_restaurant': {
      'en': 'Fast food',
      'pt-PT': 'Fast food',
      'pt-BR': 'Fast food',
    },
    'steakhouse': {
      'en': 'Steakhouse',
      'pt-PT': 'Steakhouse',
      'pt-BR': 'Steakhouse',
    },
    'pizzeria': {'en': 'Pizzeria', 'pt-PT': 'Pizzaria', 'pt-BR': 'Pizzaria'},
    'acai_shop': {
      'en': 'Açaí shop',
      'pt-PT': 'Loja de açaí',
      'pt-BR': 'Loja de açaí',
    },
    'ice_cream_shop': {
      'en': 'Ice cream shop',
      'pt-PT': 'Gelataria',
      'pt-BR': 'Sorveteria',
    },
    'juice_shop': {
      'en': 'Juice bar',
      'pt-PT': 'Loja de sumos',
      'pt-BR': 'Loja de sucos',
    },
    'cake_shop': {
      'en': 'Cake shop',
      'pt-PT': 'Pastelaria',
      'pt-BR': 'Confeitaria',
    },
    'chocolate_shop': {
      'en': 'Chocolate shop',
      'pt-PT': 'Chocolataria',
      'pt-BR': 'Chocolateria',
    },
    'donut_shop': {
      'en': 'Donut shop',
      'pt-PT': 'Loja de donuts',
      'pt-BR': 'Loja de donuts',
    },
    'sandwich_shop': {
      'en': 'Sandwich shop',
      'pt-PT': 'Casa de sandes',
      'pt-BR': 'Lanchonete',
    },
    'snack_bar': {
      'en': 'Snack bar',
      'pt-PT': 'Snack-bar',
      'pt-BR': 'Lanchonete',
    },
    'tea_house': {
      'en': 'Tea house',
      'pt-PT': 'Casa de chá',
      'pt-BR': 'Casa de chá',
    },
    'food_truck': {
      'en': 'Food truck',
      'pt-PT': 'Food truck',
      'pt-BR': 'Food truck',
    },
    'food_court': {
      'en': 'Food court',
      'pt-PT': 'Praça de alimentação',
      'pt-BR': 'Praça de alimentação',
    },
    'food_hall': {
      'en': 'Food hall',
      'pt-PT': 'Mercado gastronómico',
      'pt-BR': 'Mercado gastronômico',
    },
    'market': {'en': 'Market', 'pt-PT': 'Mercado', 'pt-BR': 'Mercado'},
    'farmers_market': {
      'en': 'Farmers market',
      'pt-PT': 'Mercado de produtores',
      'pt-BR': 'Feira de produtores',
    },
    'flea_market': {
      'en': 'Flea market',
      'pt-PT': 'Feira da ladra',
      'pt-BR': 'Mercado de pulgas',
    },
    'outdoor_market': {
      'en': 'Outdoor market',
      'pt-PT': 'Mercado ao ar livre',
      'pt-BR': 'Mercado ao ar livre',
    },
    'grocery_store': {
      'en': 'Grocery store',
      'pt-PT': 'Mercearia',
      'pt-BR': 'Mercearia',
    },
    'wine_store': {
      'en': 'Wine store',
      'pt-PT': 'Garrafeira',
      'pt-BR': 'Loja de vinhos',
    },
    'winery': {'en': 'Winery', 'pt-PT': 'Adega', 'pt-BR': 'Vinícola'},
    'vineyard': {'en': 'Vineyard', 'pt-PT': 'Vinha', 'pt-BR': 'Vinhedo'},
    'brewery': {'en': 'Brewery', 'pt-PT': 'Cervejaria', 'pt-BR': 'Cervejaria'},
    'brewpub': {'en': 'Brewpub', 'pt-PT': 'Brewpub', 'pt-BR': 'Brewpub'},
    'distillery': {
      'en': 'Distillery',
      'pt-PT': 'Destilaria',
      'pt-BR': 'Destilaria',
    },
    'beer_garden': {
      'en': 'Beer garden',
      'pt-PT': 'Jardim de cerveja',
      'pt-BR': 'Beer garden',
    },
    'cocktail_bar': {
      'en': 'Cocktail bar',
      'pt-PT': 'Bar de cocktails',
      'pt-BR': 'Bar de coquetéis',
    },
    'rooftop_bar': {
      'en': 'Rooftop bar',
      'pt-PT': 'Rooftop bar',
      'pt-BR': 'Rooftop bar',
    },
    'sports_bar': {
      'en': 'Sports bar',
      'pt-PT': 'Bar desportivo',
      'pt-BR': 'Bar esportivo',
    },
    'karaoke_bar': {
      'en': 'Karaoke bar',
      'pt-PT': 'Bar de karaoke',
      'pt-BR': 'Bar de karaokê',
    },
    'irish_pub': {
      'en': 'Irish pub',
      'pt-PT': 'Pub irlandês',
      'pt-BR': 'Pub irlandês',
    },
    'pub': {'en': 'Pub', 'pt-PT': 'Pub', 'pt-BR': 'Pub'},
    'gastropub': {
      'en': 'Gastropub',
      'pt-PT': 'Gastropub',
      'pt-BR': 'Gastropub',
    },
    'nightclub': {'en': 'Nightclub', 'pt-PT': 'Discoteca', 'pt-BR': 'Balada'},
    'lounge': {'en': 'Lounge', 'pt-PT': 'Lounge', 'pt-BR': 'Lounge'},
    'jazz_club': {
      'en': 'Jazz club',
      'pt-PT': 'Clube de jazz',
      'pt-BR': 'Clube de jazz',
    },
    'live_music_venue': {
      'en': 'Live music venue',
      'pt-PT': 'Casa de música ao vivo',
      'pt-BR': 'Casa de shows',
    },
    'concert_hall': {
      'en': 'Concert hall',
      'pt-PT': 'Sala de concertos',
      'pt-BR': 'Casa de shows',
    },
    'music_venue': {
      'en': 'Music venue',
      'pt-PT': 'Sala de espetáculos',
      'pt-BR': 'Casa de shows',
    },
    'opera_house': {'en': 'Opera house', 'pt-PT': 'Ópera', 'pt-BR': 'Ópera'},
    'theater': {'en': 'Theatre', 'pt-PT': 'Teatro', 'pt-BR': 'Teatro'},
    'cinema': {'en': 'Cinema', 'pt-PT': 'Cinema', 'pt-BR': 'Cinema'},
    'library': {'en': 'Library', 'pt-PT': 'Biblioteca', 'pt-BR': 'Biblioteca'},
    'cultural_center': {
      'en': 'Cultural centre',
      'pt-PT': 'Centro cultural',
      'pt-BR': 'Centro cultural',
    },
    'gym': {'en': 'Gym', 'pt-PT': 'Ginásio', 'pt-BR': 'Academia'},
    'fitness_center': {
      'en': 'Fitness centre',
      'pt-PT': 'Ginásio',
      'pt-BR': 'Academia',
    },
    'yoga_studio': {
      'en': 'Yoga studio',
      'pt-PT': 'Estúdio de yoga',
      'pt-BR': 'Estúdio de yoga',
    },
    'pilates_studio': {
      'en': 'Pilates studio',
      'pt-PT': 'Estúdio de pilates',
      'pt-BR': 'Estúdio de pilates',
    },
    'padel_club': {
      'en': 'Padel club',
      'pt-PT': 'Clube de padel',
      'pt-BR': 'Clube de padel',
    },
    'tennis_club': {
      'en': 'Tennis club',
      'pt-PT': 'Clube de ténis',
      'pt-BR': 'Clube de tênis',
    },
    'surf_school': {
      'en': 'Surf school',
      'pt-PT': 'Escola de surf',
      'pt-BR': 'Escola de surf',
    },
    'swimming_pool': {
      'en': 'Swimming pool',
      'pt-PT': 'Piscina',
      'pt-BR': 'Piscina',
    },
    'stadium': {'en': 'Stadium', 'pt-PT': 'Estádio', 'pt-BR': 'Estádio'},
    'sports_club': {
      'en': 'Sports club',
      'pt-PT': 'Clube desportivo',
      'pt-BR': 'Clube esportivo',
    },
    'viewpoint': {'en': 'Viewpoint', 'pt-PT': 'Miradouro', 'pt-BR': 'Mirante'},
    'garden': {'en': 'Garden', 'pt-PT': 'Jardim', 'pt-BR': 'Jardim'},
    'botanical_garden': {
      'en': 'Botanical garden',
      'pt-PT': 'Jardim botânico',
      'pt-BR': 'Jardim botânico',
    },
    'national_park': {
      'en': 'National park',
      'pt-PT': 'Parque nacional',
      'pt-BR': 'Parque nacional',
    },
    'dog_park': {
      'en': 'Dog park',
      'pt-PT': 'Parque canino',
      'pt-BR': 'Parque para cães',
    },
    'playground': {
      'en': 'Playground',
      'pt-PT': 'Parque infantil',
      'pt-BR': 'Playground',
    },
    'castle': {'en': 'Castle', 'pt-PT': 'Castelo', 'pt-BR': 'Castelo'},
    'palace': {'en': 'Palace', 'pt-PT': 'Palácio', 'pt-BR': 'Palácio'},
    'amusement_park': {
      'en': 'Amusement park',
      'pt-PT': 'Parque de diversões',
      'pt-BR': 'Parque de diversões',
    },
    'water_park': {
      'en': 'Water park',
      'pt-PT': 'Parque aquático',
      'pt-BR': 'Parque aquático',
    },
    'zoo': {'en': 'Zoo', 'pt-PT': 'Jardim zoológico', 'pt-BR': 'Zoológico'},
    'aquarium': {'en': 'Aquarium', 'pt-PT': 'Aquário', 'pt-BR': 'Aquário'},
    'planetarium': {
      'en': 'Planetarium',
      'pt-PT': 'Planetário',
      'pt-BR': 'Planetário',
    },
    'escape_room': {
      'en': 'Escape room',
      'pt-PT': 'Escape room',
      'pt-BR': 'Escape room',
    },
    'bowling_alley': {'en': 'Bowling', 'pt-PT': 'Bowling', 'pt-BR': 'Boliche'},
    'spa': {'en': 'Spa', 'pt-PT': 'Spa', 'pt-BR': 'Spa'},
    'sauna': {'en': 'Sauna', 'pt-PT': 'Sauna', 'pt-BR': 'Sauna'},
    'thermal_baths': {
      'en': 'Thermal baths',
      'pt-PT': 'Termas',
      'pt-BR': 'Termas',
    },
    'coworking_space': {
      'en': 'Coworking space',
      'pt-PT': 'Coworking',
      'pt-BR': 'Coworking',
    },
    'art_studio': {
      'en': 'Art studio',
      'pt-PT': 'Estúdio de arte',
      'pt-BR': 'Estúdio de arte',
    },
    'pottery_studio': {
      'en': 'Pottery studio',
      'pt-PT': 'Estúdio de cerâmica',
      'pt-BR': 'Estúdio de cerâmica',
    },
    'dance_studio': {
      'en': 'Dance studio',
      'pt-PT': 'Estúdio de dança',
      'pt-BR': 'Estúdio de dança',
    },
    'record_store': {
      'en': 'Record store',
      'pt-PT': 'Loja de discos',
      'pt-BR': 'Loja de discos',
    },
    'vintage_store': {
      'en': 'Vintage store',
      'pt-PT': 'Loja vintage',
      'pt-BR': 'Loja vintage',
    },
    'shopping_mall': {
      'en': 'Shopping mall',
      'pt-PT': 'Centro comercial',
      'pt-BR': 'Shopping',
    },
    'event_venue': {
      'en': 'Event venue',
      'pt-PT': 'Espaço de eventos',
      'pt-BR': 'Espaço de eventos',
    },
    'event_space': {
      'en': 'Event space',
      'pt-PT': 'Espaço de eventos',
      'pt-BR': 'Espaço de eventos',
    },
    'casino': {'en': 'Casino', 'pt-PT': 'Casino', 'pt-BR': 'Cassino'},
    'restaurant': {
      'en': 'Restaurant',
      'pt-PT': 'Restaurante',
      'pt-BR': 'Restaurante',
    },
    'cafe': {'en': 'Café', 'pt-PT': 'Café', 'pt-BR': 'Café'},
    'bar': {'en': 'Bar', 'pt-PT': 'Bar', 'pt-BR': 'Bar'},
    'wine_bar': {
      'en': 'Wine bar',
      'pt-PT': 'Bar de vinhos',
      'pt-BR': 'Bar de vinhos',
    },
    'bakery': {'en': 'Bakery', 'pt-PT': 'Padaria', 'pt-BR': 'Padaria'},
    'pastry': {
      'en': 'Pastry shop',
      'pt-PT': 'Pastelaria',
      'pt-BR': 'Confeitaria',
    },
    'bookstore': {'en': 'Bookstore', 'pt-PT': 'Livraria', 'pt-BR': 'Livraria'},
    'art_gallery': {
      'en': 'Art gallery',
      'pt-PT': 'Galeria de arte',
      'pt-BR': 'Galeria de arte',
    },
    'museum': {'en': 'Museum', 'pt-PT': 'Museu', 'pt-BR': 'Museu'},
    'park': {'en': 'Park', 'pt-PT': 'Parque', 'pt-BR': 'Parque'},
    'beach': {'en': 'Beach', 'pt-PT': 'Praia', 'pt-BR': 'Praia'},
    'hiking_trail': {
      'en': 'Hiking trail',
      'pt-PT': 'Trilho',
      'pt-BR': 'Trilha',
    },
    'comedy_club': {
      'en': 'Comedy club',
      'pt-PT': 'Clube de comédia',
      'pt-BR': 'Clube de comédia',
    },
    'italian_restaurant': {
      'en': 'Italian restaurant',
      'pt-PT': 'Restaurante italiano',
      'pt-BR': 'Restaurante italiano',
    },
    'japanese_restaurant': {
      'en': 'Japanese restaurant',
      'pt-PT': 'Restaurante japonês',
      'pt-BR': 'Restaurante japonês',
    },
    'portuguese_restaurant': {
      'en': 'Portuguese restaurant',
      'pt-PT': 'Restaurante português',
      'pt-BR': 'Restaurante português',
    },
  },
  'event_categories': {
    // Generated from the backend taxonomy (CATEGORY_LABELS) — the single
    // source of truth for chip copy. Regenerate when the taxonomy moves.
    'activism & community': {
      'en': 'Activism & community',
      'pt-PT': 'Ativismo e comunidade',
      'pt-BR': 'Ativismo e comunidade',
      'es-MX': 'Activismo y comunidad',
    },
    'art': {'en': 'Art', 'pt-PT': 'Arte', 'pt-BR': 'Arte', 'es-MX': 'Arte'},
    'business & networking': {
      'en': 'Business & networking',
      'pt-PT': 'Negócios e networking',
      'pt-BR': 'Negócios e networking',
      'es-MX': 'Negocios y networking',
    },
    'commerce & shopping': {
      'en': 'Commerce & shopping',
      'pt-PT': 'Comércio e compras',
      'pt-BR': 'Comércio e compras',
      'es-MX': 'Comercio y compras',
    },
    'culture': {
      'en': 'Culture',
      'pt-PT': 'Cultura',
      'pt-BR': 'Cultura',
      'es-MX': 'Cultura',
    },
    'education & talks': {
      'en': 'Education & talks',
      'pt-PT': 'Educação e conferências',
      'pt-BR': 'Educação e palestras',
      'es-MX': 'Educación y charlas',
    },
    'family & kids': {
      'en': 'Family & kids',
      'pt-PT': 'Família e crianças',
      'pt-BR': 'Família e crianças',
      'es-MX': 'Familia y niños',
    },
    'food & drink': {
      'en': 'Food & drink',
      'pt-PT': 'Comida e bebida',
      'pt-BR': 'Comida e bebida',
      'es-MX': 'Comida y bebida',
    },
    'gaming & esports': {
      'en': 'Gaming & esports',
      'pt-PT': 'Jogos e esports',
      'pt-BR': 'Games e esports',
      'es-MX': 'Videojuegos y esports',
    },
    'general': {
      'en': 'General',
      'pt-PT': 'Geral',
      'pt-BR': 'Geral',
      'es-MX': 'General',
    },
    'music': {
      'en': 'Music',
      'pt-PT': 'Música',
      'pt-BR': 'Música',
      'es-MX': 'Música',
    },
    'nature & outdoors': {
      'en': 'Nature & outdoors',
      'pt-PT': 'Natureza e ar livre',
      'pt-BR': 'Natureza e ar livre',
      'es-MX': 'Naturaleza y aire libre',
    },
    'nightlife & parties': {
      'en': 'Nightlife & parties',
      'pt-PT': 'Vida noturna e festas',
      'pt-BR': 'Vida noturna e festas',
      'es-MX': 'Vida nocturna y fiestas',
    },
    'religion & spirituality': {
      'en': 'Religion & spirituality',
      'pt-PT': 'Religião e espiritualidade',
      'pt-BR': 'Religião e espiritualidade',
      'es-MX': 'Religión y espiritualidad',
    },
    'sport': {
      'en': 'Sport',
      'pt-PT': 'Desporto',
      'pt-BR': 'Esporte',
      'es-MX': 'Deporte',
    },
    'tech & startups': {
      'en': 'Tech & startups',
      'pt-PT': 'Tecnologia e startups',
      'pt-BR': 'Tecnologia e startups',
      'es-MX': 'Tecnología y startups',
    },
    'volunteer work': {
      'en': 'Volunteer work',
      'pt-PT': 'Voluntariado',
      'pt-BR': 'Trabalho voluntário',
      'es-MX': 'Voluntariado',
    },
    'wellness & health': {
      'en': 'Wellness & health',
      'pt-PT': 'Bem-estar e saúde',
      'pt-BR': 'Bem-estar e saúde',
      'es-MX': 'Bienestar y salud',
    },
  },
  'event_sub_categories': {
    // Generated from the backend taxonomy (SUB_CATEGORY_LABELS, 100 slugs)
    // + curated wording overrides + common open PROPOSALS seen in prod
    // (sport-football etc.). Chips were falling to the mechanical English
    // tail for every slug this map did not carry.
    'activism-community-meeting': {
      'en': 'Community meeting',
      'pt-PT': 'Encontro comunitário',
      'pt-BR': 'Encontro comunitário',
      'es-MX': 'Reunión comunitaria',
    },
    'activism-protest': {
      'en': 'Protest',
      'pt-PT': 'Protesto',
      'pt-BR': 'Protesto',
      'es-MX': 'Protesta',
    },
    'art-exhibition': {
      'en': 'Exhibition',
      'pt-PT': 'Exposição',
      'pt-BR': 'Exposição',
      'es-MX': 'Exposición',
    },
    'art-installation': {
      'en': 'Installation',
      'pt-PT': 'Instalação',
      'pt-BR': 'Instalação',
      'es-MX': 'Instalación',
    },
    'art-modern': {
      'en': 'Modern art',
      'pt-PT': 'Arte moderna',
      'pt-BR': 'Arte moderna',
      'es-MX': 'Arte moderno',
    },
    'art-photography': {
      'en': 'Photography',
      'pt-PT': 'Fotografia',
      'pt-BR': 'Fotografia',
      'es-MX': 'Fotografía',
    },
    'art-street-art': {
      'en': 'Street art',
      'pt-PT': 'Arte urbana',
      'pt-BR': 'Arte de rua',
      'es-MX': 'Arte urbano',
    },
    'art-workshop': {
      'en': 'Workshop',
      'pt-PT': 'Oficina',
      'pt-BR': 'Oficina',
      'es-MX': 'Taller',
    },
    'business-career': {
      'en': 'Career',
      'pt-PT': 'Carreira',
      'pt-BR': 'Carreira',
      'es-MX': 'Carrera',
    },
    'business-conference': {
      'en': 'Conference',
      'pt-PT': 'Conferência',
      'pt-BR': 'Conferência',
      'es-MX': 'Conferencia',
    },
    'business-networking': {
      'en': 'Networking',
      'pt-PT': 'Networking',
      'pt-BR': 'Networking',
      'es-MX': 'Networking',
    },
    'commerce-clothing': {
      'en': 'Clothing',
      'pt-PT': 'Roupa',
      'pt-BR': 'Roupas',
      'es-MX': 'Ropa',
    },
    'commerce-crafts': {
      'en': 'Crafts',
      'pt-PT': 'Artesanato',
      'pt-BR': 'Artesanato',
      'es-MX': 'Artesanías',
    },
    'commerce-general': {
      'en': 'General',
      'pt-PT': 'Geral',
      'pt-BR': 'Geral',
      'es-MX': 'General',
    },
    'commerce-tech': {
      'en': 'Tech',
      'pt-PT': 'Tecnologia',
      'pt-BR': 'Tecnologia',
      'es-MX': 'Tecnología',
    },
    'commerce-vintage': {
      'en': 'Vintage',
      'pt-PT': 'Vintage',
      'pt-BR': 'Vintage',
      'es-MX': 'Vintage',
    },
    'culture-cinema': {
      'en': 'Cinema',
      'pt-PT': 'Cinema',
      'pt-BR': 'Cinema',
      'es-MX': 'Cine',
    },
    'culture-circus': {
      'en': 'Circus',
      'pt-PT': 'Circo',
      'pt-BR': 'Circo',
      'es-MX': 'Circo',
    },
    'culture-comedy': {
      'en': 'Comedy',
      'pt-PT': 'Comédia',
      'pt-BR': 'Comédia',
      'es-MX': 'Comedia',
    },
    'culture-craft-workshop': {
      'en': 'Craft workshop',
      'pt-PT': 'Oficina de artesanato',
      'pt-BR': 'Oficina de artesanato',
      'es-MX': 'Taller de artesanía',
    },
    'culture-dance': {
      'en': 'Dance',
      'pt-PT': 'Dança',
      'pt-BR': 'Dança',
      'es-MX': 'Danza',
    },
    'culture-festival': {
      'en': 'Festival',
      'pt-PT': 'Festival',
      'pt-BR': 'Festival',
      'es-MX': 'Festival',
    },
    'culture-film-festival': {
      'en': 'Film festival',
      'pt-PT': 'Festival de cinema',
      'pt-BR': 'Festival de cinema',
      'es-MX': 'Festival de cine',
    },
    'culture-heritage-tour': {
      'en': 'Heritage tour',
      'pt-PT': 'Visita ao património',
      'pt-BR': 'Passeio histórico',
      'es-MX': 'Recorrido patrimonial',
    },
    'culture-literature': {
      'en': 'Literature',
      'pt-PT': 'Literatura',
      'pt-BR': 'Literatura',
      'es-MX': 'Literatura',
    },
    'culture-local-fair': {
      'en': 'Local fair',
      'pt-PT': 'Feira local',
      'pt-BR': 'Feira local',
      'es-MX': 'Feria local',
    },
    'culture-opera': {
      'en': 'Opera',
      'pt-PT': 'Ópera',
      'pt-BR': 'Ópera',
      'es-MX': 'Ópera',
    },
    'culture-performance': {
      'en': 'Performance',
      'pt-PT': 'Performance',
      'pt-BR': 'Performance',
      'es-MX': 'Performance',
    },
    'culture-theatre': {
      'en': 'Theatre',
      'pt-PT': 'Teatro',
      'pt-BR': 'Teatro',
      'es-MX': 'Teatro',
    },
    'education-conference': {
      'en': 'Conference',
      'pt-PT': 'Conferência',
      'pt-BR': 'Conferência',
      'es-MX': 'Conferencia',
    },
    'education-hackathon': {
      'en': 'Hackathon',
      'pt-PT': 'Hackathon',
      'pt-BR': 'Hackathon',
      'es-MX': 'Hackatón',
    },
    'education-talk': {
      'en': 'Talk',
      'pt-PT': 'Palestra',
      'pt-BR': 'Palestra',
      'es-MX': 'Charla',
    },
    'education-workshop': {
      'en': 'Workshop',
      'pt-PT': 'Oficina',
      'pt-BR': 'Oficina',
      'es-MX': 'Taller',
    },
    'family-activity': {
      'en': 'Family activity',
      'pt-PT': 'Atividade em família',
      'pt-BR': 'Atividade em família',
      'es-MX': 'Actividad familiar',
    },
    'family-kids': {
      'en': 'Kids',
      'pt-PT': 'Crianças',
      'pt-BR': 'Crianças',
      'es-MX': 'Niños',
    },
    'food-bar': {'en': 'Bar', 'pt-PT': 'Bar', 'pt-BR': 'Bar', 'es-MX': 'Bar'},
    'food-brunch': {
      'en': 'Brunch',
      'pt-PT': 'Brunch',
      'pt-BR': 'Brunch',
      'es-MX': 'Brunch',
    },
    'food-cafe': {
      'en': 'Café',
      'pt-PT': 'Café',
      'pt-BR': 'Café',
      'es-MX': 'Café',
    },
    'food-cooking-class': {
      'en': 'Cooking class',
      'pt-PT': 'Aula de cozinha',
      'pt-BR': 'Aula de culinária',
      'es-MX': 'Clase de cocina',
    },
    'food-market': {
      'en': 'Food market',
      'pt-PT': 'Mercado gastronómico',
      'pt-BR': 'Mercado gastronômico',
      'es-MX': 'Mercado gastronómico',
    },
    'food-pop-up': {
      'en': 'Pop-up',
      'pt-PT': 'Pop-up',
      'pt-BR': 'Pop-up',
      'es-MX': 'Pop-up',
    },
    'food-restaurant': {
      'en': 'Restaurant',
      'pt-PT': 'Restaurante',
      'pt-BR': 'Restaurante',
      'es-MX': 'Restaurante',
    },
    'food-tasting': {
      'en': 'Tasting',
      'pt-PT': 'Prova',
      'pt-BR': 'Degustação',
      'es-MX': 'Cata',
    },
    'gaming-board-games': {
      'en': 'Board games',
      'pt-PT': 'Jogos de tabuleiro',
      'pt-BR': 'Jogos de tabuleiro',
      'es-MX': 'Juegos de mesa',
    },
    'gaming-esports': {
      'en': 'Esports',
      'pt-PT': 'Esports',
      'pt-BR': 'Esports',
      'es-MX': 'Esports',
    },
    'gaming-trivia': {
      'en': 'Trivia night',
      'pt-PT': 'Noite de quiz',
      'pt-BR': 'Noite de quiz',
      'es-MX': 'Trivia',
    },
    'gaming-video-games': {
      'en': 'Video games',
      'pt-PT': 'Videojogos',
      'pt-BR': 'Videogames',
      'es-MX': 'Videojuegos',
    },
    'music-accordion': {
      'en': 'Accordion music',
      'pt-PT': 'Acordeão',
      'pt-BR': 'Acordeão',
      'es-MX': 'Acordeón',
    },
    'music-classical': {
      'en': 'Classical',
      'pt-PT': 'Clássica',
      'pt-BR': 'Clássica',
      'es-MX': 'Clásica',
    },
    'music-country': {
      'en': 'Country',
      'pt-PT': 'Country',
      'pt-BR': 'Country',
      'es-MX': 'Country',
    },
    'music-dj': {
      'en': 'DJ set',
      'pt-PT': 'DJ set',
      'pt-BR': 'DJ set',
      'es-MX': 'DJ set',
    },
    'music-electronic': {
      'en': 'Electronic music',
      'pt-PT': 'Eletrónica',
      'pt-BR': 'Eletrônica',
      'es-MX': 'Electrónica',
    },
    'music-fado': {
      'en': 'Fado',
      'pt-PT': 'Fado',
      'pt-BR': 'Fado',
      'es-MX': 'Fado',
    },
    'music-festival': {
      'en': 'Festival',
      'pt-PT': 'Festival',
      'pt-BR': 'Festival',
      'es-MX': 'Festival',
    },
    'music-folk': {
      'en': 'Folk',
      'pt-PT': 'Folk',
      'pt-BR': 'Folk',
      'es-MX': 'Folk',
    },
    'music-hiphop': {
      'en': 'Hip-hop',
      'pt-PT': 'Hip-hop',
      'pt-BR': 'Hip-hop',
      'es-MX': 'Hip-hop',
    },
    'music-indie': {
      'en': 'Indie',
      'pt-PT': 'Indie',
      'pt-BR': 'Indie',
      'es-MX': 'Indie',
    },
    'music-jazz': {
      'en': 'Jazz',
      'pt-PT': 'Jazz',
      'pt-BR': 'Jazz',
      'es-MX': 'Jazz',
    },
    'music-latin': {
      'en': 'Latin',
      'pt-PT': 'Latina',
      'pt-BR': 'Latina',
      'es-MX': 'Latina',
    },
    'music-live': {
      'en': 'Live music',
      'pt-PT': 'Música ao vivo',
      'pt-BR': 'Música ao vivo',
      'es-MX': 'Música en vivo',
    },
    'music-metal': {
      'en': 'Metal',
      'pt-PT': 'Metal',
      'pt-BR': 'Metal',
      'es-MX': 'Metal',
    },
    'music-pop': {'en': 'Pop', 'pt-PT': 'Pop', 'pt-BR': 'Pop', 'es-MX': 'Pop'},
    'music-reggae': {
      'en': 'Reggae',
      'pt-PT': 'Reggae',
      'pt-BR': 'Reggae',
      'es-MX': 'Reggae',
    },
    'music-rock': {
      'en': 'Rock',
      'pt-PT': 'Rock',
      'pt-BR': 'Rock',
      'es-MX': 'Rock',
    },
    'music-sertanejo': {
      'en': 'Sertanejo',
      'pt-PT': 'Sertanejo',
      'pt-BR': 'Sertanejo',
      'es-MX': 'Sertanejo',
    },
    'music-workshop': {
      'en': 'Workshop',
      'pt-PT': 'Oficina',
      'pt-BR': 'Oficina',
      'es-MX': 'Taller',
    },
    'music-world': {
      'en': 'World music',
      'pt-PT': 'Música do mundo',
      'pt-BR': 'Música do mundo',
      'es-MX': 'Música del mundo',
    },
    'nature-beach': {
      'en': 'Beach',
      'pt-PT': 'Praia',
      'pt-BR': 'Praia',
      'es-MX': 'Playa',
    },
    'nature-hiking': {
      'en': 'Hiking',
      'pt-PT': 'Caminhada',
      'pt-BR': 'Trilha',
      'es-MX': 'Senderismo',
    },
    'nature-hiking-trail': {
      'en': 'Hiking trails',
      'pt-PT': 'Trilhos',
      'pt-BR': 'Trilhas',
      'es-MX': 'Senderismo',
    },
    'nature-park': {
      'en': 'Park',
      'pt-PT': 'Parque',
      'pt-BR': 'Parque',
      'es-MX': 'Parque',
    },
    'nature-workshop': {
      'en': 'Workshop',
      'pt-PT': 'Oficina',
      'pt-BR': 'Oficina',
      'es-MX': 'Taller',
    },
    'nightlife-bar': {
      'en': 'Bar',
      'pt-PT': 'Bar',
      'pt-BR': 'Bar',
      'es-MX': 'Bar',
    },
    'nightlife-boat-party': {
      'en': 'Boat party',
      'pt-PT': 'Festa de barco',
      'pt-BR': 'Festa de barco',
      'es-MX': 'Fiesta en barco',
    },
    'nightlife-club': {
      'en': 'Club',
      'pt-PT': 'Discoteca',
      'pt-BR': 'Balada',
      'es-MX': 'Club',
    },
    'nightlife-karaoke': {
      'en': 'Karaoke',
      'pt-PT': 'Karaoke',
      'pt-BR': 'Karaokê',
      'es-MX': 'Karaoke',
    },
    'nightlife-party': {
      'en': 'Party',
      'pt-PT': 'Festa',
      'pt-BR': 'Festa',
      'es-MX': 'Fiesta',
    },
    'religion-afro-brazilian': {
      'en': 'Afro-Brazilian',
      'pt-PT': 'Afro-brasileiro',
      'pt-BR': 'Afro-brasileiro',
      'es-MX': 'Afrobrasileño',
    },
    'religion-buddhism': {
      'en': 'Buddhism',
      'pt-PT': 'Budismo',
      'pt-BR': 'Budismo',
      'es-MX': 'Budismo',
    },
    'religion-catholic': {
      'en': 'Catholic',
      'pt-PT': 'Católico',
      'pt-BR': 'Católico',
      'es-MX': 'Católico',
    },
    'religion-evangelical': {
      'en': 'Evangelical',
      'pt-PT': 'Evangélico',
      'pt-BR': 'Evangélico',
      'es-MX': 'Evangélico',
    },
    'religion-hinduism': {
      'en': 'Hinduism',
      'pt-PT': 'Hinduísmo',
      'pt-BR': 'Hinduísmo',
      'es-MX': 'Hinduismo',
    },
    'religion-islam': {
      'en': 'Islam',
      'pt-PT': 'Islão',
      'pt-BR': 'Islã',
      'es-MX': 'Islam',
    },
    'religion-judaism': {
      'en': 'Judaism',
      'pt-PT': 'Judaísmo',
      'pt-BR': 'Judaísmo',
      'es-MX': 'Judaísmo',
    },
    'religion-other': {
      'en': 'Other',
      'pt-PT': 'Outro',
      'pt-BR': 'Outro',
      'es-MX': 'Otro',
    },
    'religion-spiritual': {
      'en': 'Spiritual',
      'pt-PT': 'Espiritual',
      'pt-BR': 'Espiritual',
      'es-MX': 'Espiritual',
    },
    'sport-fitness': {
      'en': 'Fitness',
      'pt-PT': 'Fitness',
      'pt-BR': 'Fitness',
      'es-MX': 'Fitness',
    },
    'sport-football': {
      'en': 'Football',
      'pt-PT': 'Futebol',
      'pt-BR': 'Futebol',
      'es-MX': 'Fútbol',
    },
    'sport-golf': {
      'en': 'Golf',
      'pt-PT': 'Golfe',
      'pt-BR': 'Golfe',
      'es-MX': 'Golf',
    },
    'sport-martial-arts': {
      'en': 'Martial arts',
      'pt-PT': 'Artes marciais',
      'pt-BR': 'Artes marciais',
      'es-MX': 'Artes marciales',
    },
    'sport-padel': {
      'en': 'Padel',
      'pt-PT': 'Padel',
      'pt-BR': 'Padel',
      'es-MX': 'Pádel',
    },
    'sport-running': {
      'en': 'Running',
      'pt-PT': 'Corrida',
      'pt-BR': 'Corrida',
      'es-MX': 'Running',
    },
    'sport-surfing': {
      'en': 'Surfing',
      'pt-PT': 'Surf',
      'pt-BR': 'Surfe',
      'es-MX': 'Surf',
    },
    'sport-tennis': {
      'en': 'Tennis',
      'pt-PT': 'Ténis',
      'pt-BR': 'Tênis',
      'es-MX': 'Tenis',
    },
    'sport-volleyball': {
      'en': 'Volleyball',
      'pt-PT': 'Voleibol',
      'pt-BR': 'Vôlei',
      'es-MX': 'Voleibol',
    },
    'tech-conference': {
      'en': 'Conference',
      'pt-PT': 'Conferência',
      'pt-BR': 'Conferência',
      'es-MX': 'Conferencia',
    },
    'tech-hackathon': {
      'en': 'Hackathon',
      'pt-PT': 'Hackathon',
      'pt-BR': 'Hackathon',
      'es-MX': 'Hackatón',
    },
    'tech-meetup': {
      'en': 'Tech meetup',
      'pt-PT': 'Meetup de tecnologia',
      'pt-BR': 'Meetup de tecnologia',
      'es-MX': 'Meetup de tecnología',
    },
    'tech-workshop': {
      'en': 'Workshop',
      'pt-PT': 'Oficina',
      'pt-BR': 'Oficina',
      'es-MX': 'Taller',
    },
    'volunteer-animal': {
      'en': 'Animals',
      'pt-PT': 'Animais',
      'pt-BR': 'Animais',
      'es-MX': 'Animales',
    },
    'volunteer-community': {
      'en': 'Community',
      'pt-PT': 'Comunidade',
      'pt-BR': 'Comunidade',
      'es-MX': 'Comunidad',
    },
    'volunteer-education': {
      'en': 'Education',
      'pt-PT': 'Educação',
      'pt-BR': 'Educação',
      'es-MX': 'Educación',
    },
    'volunteer-environment': {
      'en': 'Environment',
      'pt-PT': 'Ambiente',
      'pt-BR': 'Meio ambiente',
      'es-MX': 'Medio ambiente',
    },
    'volunteer-health': {
      'en': 'Health',
      'pt-PT': 'Saúde',
      'pt-BR': 'Saúde',
      'es-MX': 'Salud',
    },
    'volunteer-social': {
      'en': 'Social',
      'pt-PT': 'Social',
      'pt-BR': 'Social',
      'es-MX': 'Social',
    },
    'wellness-meditation': {
      'en': 'Meditation',
      'pt-PT': 'Meditação',
      'pt-BR': 'Meditação',
      'es-MX': 'Meditación',
    },
    'wellness-retreat': {
      'en': 'Retreat',
      'pt-PT': 'Retiro',
      'pt-BR': 'Retiro',
      'es-MX': 'Retiro',
    },
    'wellness-workshop': {
      'en': 'Workshop',
      'pt-PT': 'Oficina',
      'pt-BR': 'Oficina',
      'es-MX': 'Taller',
    },
    'wellness-yoga': {
      'en': 'Yoga',
      'pt-PT': 'Yoga',
      'pt-BR': 'Yoga',
      'es-MX': 'Yoga',
    },
  },
  'budget_level': {
    'free': {'en': 'Free', 'pt-PT': 'Gratuito', 'pt-BR': 'Grátis'},
    'cheap': {'en': 'Cheap', 'pt-PT': 'Barato', 'pt-BR': 'Barato'},
    'moderate': {'en': 'Moderate', 'pt-PT': 'Moderado', 'pt-BR': 'Moderado'},
    'expensive': {'en': 'Expensive', 'pt-PT': 'Caro', 'pt-BR': 'Caro'},
    'very_expensive': {
      'en': 'Very expensive',
      'pt-PT': 'Muito caro',
      'pt-BR': 'Muito caro',
    },
  },
  'accessibility': {
    'wheelchair_accessible': {
      'en': 'Wheelchair accessible',
      'pt-PT': 'Acessível a cadeiras de rodas',
      'pt-BR': 'Acessível para cadeirantes',
    },
    'hearing_loop': {
      'en': 'Hearing loop',
      'pt-PT': 'Anel de indução',
      'pt-BR': 'Anel auditivo',
    },
    'step_free': {
      'en': 'Step-free',
      'pt-PT': 'Sem degraus',
      'pt-BR': 'Sem degraus',
    },
    'accessible_restroom': {
      'en': 'Accessible restroom',
      'pt-PT': 'Casa de banho acessível',
      'pt-BR': 'Banheiro acessível',
    },
  },
  'party_size': {
    'solo': {'en': 'Solo', 'pt-PT': 'Sozinho', 'pt-BR': 'Sozinho'},
    'pair': {'en': 'Pair', 'pt-PT': 'Em par', 'pt-BR': 'Em dupla'},
    'small_group': {
      'en': 'Small group',
      'pt-PT': 'Grupo pequeno',
      'pt-BR': 'Grupo pequeno',
    },
    'large_group': {
      'en': 'Large group',
      'pt-PT': 'Grupo grande',
      'pt-BR': 'Grupo grande',
    },
  },
};

/// Ignore me — this exists so the i10n generated class is treated as
/// reachable from this file (we call no methods on it directly but the
/// import keeps the relative path stable).
@visibleForTesting
Type get unusedLtAnchor => Lt;
