import 'dart:async';
import 'dart:convert';

import '../../models/models.dart';
import '../interfaces/memory_twin_api.dart';

/// In-memory twin used when `useMockApiProvider` is true.
class MockMemoryTwinApi implements IMemoryTwinApi {
  MemoryTwinResponse _twin = MemoryTwinResponse.fromJson(_seed);

  static const Duration _latency = Duration(milliseconds: 250);

  @override
  Future<MemoryTwinResponse> getTwin() async {
    await Future<void>.delayed(_latency);
    return _twin;
  }

  @override
  Future<BulkClearResponse> clearAll() async {
    await Future<void>.delayed(_latency);
    final cleared = BulkClearResponse(
      deleted: {
        'user_memory_facts': _twin.families.fold<int>(
          0,
          (s, f) => s + f.observationCount,
        ),
      },
      killSwitchEngaged: false,
    );
    _twin = MemoryTwinResponse.fromJson({
      ..._seed,
      'families': const [],
      'generated_at': DateTime.now().toUtc().toIso8601String(),
    });
    return cleared;
  }

  @override
  Future<void> deleteFact(String factId) async {
    await Future<void>.delayed(_latency);
    _twin = _pruneBy((obs) => obs.backingFacts.any((f) => f.id == factId));
  }

  @override
  Future<void> deleteObservation(String observationId) async {
    await Future<void>.delayed(_latency);
    _twin = _pruneBy((obs) => obs.id == observationId);
  }

  @override
  Future<void> deleteDimension(String dimensionName) async {
    await Future<void>.delayed(_latency);
    final families = <FamilyView>[];
    for (final family in _twin.families) {
      final keptDims = family.dimensions
          .where((d) => d.name != dimensionName)
          .toList(growable: false);
      if (keptDims.isNotEmpty) {
        families.add(FamilyView(family: family.family, dimensions: keptDims));
      }
    }
    _twin = _withFamilies(families);
  }

  @override
  Future<void> suppressChip({
    required String dimension,
    String? family,
    required String value,
  }) async {
    await Future<void>.delayed(_latency);
    final target = value.toLowerCase();
    final families = <FamilyView>[];
    for (final fam in _twin.families) {
      final dims = <DimensionView>[];
      for (final dim in fam.dimensions) {
        final obs = dim.name == dimension
            ? dim.observations
                  .where((o) => o.value.toLowerCase() != target)
                  .toList(growable: false)
            : dim.observations;
        if (obs.isNotEmpty || dim.aggregated != null) {
          dims.add(
            DimensionView(
              name: dim.name,
              family: dim.family,
              state: dim.state,
              observations: obs,
              canDelete: dim.canDelete,
              aggregated: dim.aggregated,
              lastObservedAt: dim.lastObservedAt,
            ),
          );
        }
      }
      if (dims.isNotEmpty) {
        families.add(FamilyView(family: fam.family, dimensions: dims));
      }
    }
    _twin = _withFamilies(families);
  }

  @override
  Future<int> nudgeChip({
    required String dimension,
    String? family,
    required String value,
    required bool increase,
  }) async {
    await Future<void>.delayed(_latency);
    return increase ? 1 : -1;
  }

  @override
  Future<TellUsResult> tellUs(String text) async {
    await Future<void>.delayed(_latency);
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const TellUsResult(status: 'empty_input');
    }
    return TellUsResult(
      status: 'applied',
      factsWritten: 1,
      facts: ['Told us: $trimmed'],
    );
  }

  @override
  Future<List<int>> exportJson() async {
    await Future<void>.delayed(_latency);
    return utf8.encode(
      jsonEncode({
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'memory': {
          'facts': const [],
          'snapshots': const [],
          'companions': const [],
        },
      }),
    );
  }

  MemoryTwinResponse _pruneBy(bool Function(ObservationView) predicate) {
    final families = <FamilyView>[];
    for (final family in _twin.families) {
      final keptDims = <DimensionView>[];
      for (final dim in family.dimensions) {
        final keptObs = dim.observations
            .where((o) => !predicate(o))
            .toList(growable: false);
        if (keptObs.isNotEmpty) {
          keptDims.add(
            DimensionView(
              name: dim.name,
              family: dim.family,
              state: dim.state,
              observations: keptObs,
              canDelete: dim.canDelete,
              aggregated: dim.aggregated,
              lastObservedAt: dim.lastObservedAt,
            ),
          );
        }
      }
      if (keptDims.isNotEmpty) {
        families.add(FamilyView(family: family.family, dimensions: keptDims));
      }
    }
    return _withFamilies(families);
  }

  MemoryTwinResponse _withFamilies(List<FamilyView> families) {
    return MemoryTwinResponse(
      userProfileId: _twin.userProfileId,
      schemaVersion: _twin.schemaVersion,
      policyVersion: _twin.policyVersion,
      projectorVersion: _twin.projectorVersion,
      taxonomyVersion: _twin.taxonomyVersion,
      personaTags: _twin.personaTags,
      families: families,
      actionFacts: _twin.actionFacts,
      generatedAt: DateTime.now().toUtc(),
    );
  }

  static final Map<String, dynamic> _seed = {
    'user_profile_id': '00000000-0000-0000-0000-000000000001',
    'schema_version': 1,
    'policy_version': 1,
    'projector_version': 1,
    'taxonomy_version': '2026-05',
    'persona_tags': ['foodie'],
    'generated_at': '2026-05-28T10:00:00Z',
    'families': [
      {
        'family': 'cuisine',
        'dimensions': [
          {
            'name': 'cuisine.preferred',
            'family': 'cuisine',
            'state': 'known',
            'can_delete': true,
            'observations': [
              {
                'id': 'fact:f1:obs:1',
                'value': 'Loves Italian food, especially handmade pasta',
                'certainty': 0.92,
                'polarity': 'prefer',
                'strength': 'soft',
                'source_class': 'explicit_fact',
                'uses': ['ranking'],
                'observed_at': '2026-05-25T18:00:00Z',
                'evidence_text':
                    "honestly I'd eat pasta every day, I just made fresh tagliatelle at home last weekend.",
                'provenance_kind': 'message',
                'source_session_id': 'sess-1',
                'can_delete': true,
                'backing_facts': [
                  {
                    'id': 'f1',
                    'category': 'taste',
                    'content': 'Italian',
                    'source': 'user_stated',
                    'signal_strength': 'strong',
                    'persistence': 'stable',
                    'source_session_id': 'sess-1',
                    'valid_from': '2026-05-12T10:00:00Z',
                  },
                ],
              },
              {
                'id': 'fact:f2:obs:1',
                'value': 'Avoids spicy food',
                'certainty': 0.88,
                'polarity': 'avoid',
                'strength': 'hard',
                'source_class': 'explicit_fact',
                'uses': const [],
                'provenance_kind': 'onboarding',
                'can_delete': true,
                'backing_facts': [
                  {
                    'id': 'f2',
                    'category': 'restrictions',
                    'content': 'spicy',
                    'source': 'user_stated',
                    'signal_strength': 'strong',
                    'persistence': 'stable',
                    'valid_from': '2026-05-14T10:00:00Z',
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        'family': 'geographic',
        'dimensions': [
          {
            'name': 'geographic.home',
            'family': 'geographic',
            'state': 'known',
            'can_delete': true,
            'observations': [
              {
                'id': 'fact:f3:obs:1',
                'value': 'Lives in Anjos, Lisbon',
                'certainty': 0.95,
                'polarity': 'prefer',
                'strength': 'hard',
                'source_class': 'explicit_fact',
                'uses': const [],
                'provenance_kind': 'location',
                'can_delete': true,
                'backing_facts': [
                  {
                    'id': 'f3',
                    'category': 'geographic',
                    'content': 'Anjos',
                    'source': 'user_stated',
                    'signal_strength': 'strong',
                    'persistence': 'stable',
                    'valid_from': '2026-05-10T10:00:00Z',
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  };
}
