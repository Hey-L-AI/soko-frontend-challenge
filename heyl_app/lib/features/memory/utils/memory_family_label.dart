import 'package:flutter/widgets.dart';

import '../../../l10n/generated/l10n.dart';

/// Returns a human-readable label for a memory family/category key.
///
/// Known keys are resolved via ARB strings. Unknown keys fall through to
/// [memoryFamilyLabelOrFallback] which title-cases them.
String memoryFamilyLabel(BuildContext context, String key) {
  final l10n = Lt.of(context);
  // Take the head of dotted names (cuisine.preferred → cuisine).
  final head = key.split('.').first;
  switch (head) {
    case 'cuisine':
      return l10n.memoryFamilyCuisine;
    case 'dietary':
    case 'restrictions':
      return l10n.memoryFamilyDietary;
    case 'social_graph':
    case 'social':
      return l10n.memoryFamilySocialGraph;
    case 'temporal_patterns':
    case 'schedule':
      return l10n.memoryFamilyTemporalPatterns;
    case 'geographic':
    case 'neighborhood':
      return l10n.memoryFamilyGeographic;
    case 'trust_sources':
      return l10n.memoryFamilyTrustSources;
    case 'product_feedback':
      return l10n.memoryFamilyProductFeedback;
    case 'taste':
      return l10n.memoryFamilyTaste;
    default:
      return memoryFamilyLabelOrFallback(head);
  }
}

/// Pure-Dart fallback that sentence-cases an unknown snake_case key. Only
/// the first word is capitalised; the rest are lowercased. Exposed for unit
/// testing without a BuildContext.
String memoryFamilyLabelOrFallback(String key) {
  final head = key.split('.').first;
  if (head.isEmpty) return key;
  final words = head.split('_').map((w) => w.toLowerCase()).toList();
  if (words.isEmpty || words.first.isEmpty) return head;
  words[0] = '${words[0][0].toUpperCase()}${words[0].substring(1)}';
  return words.join(' ');
}
