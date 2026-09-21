import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/datasources/interfaces/memory_twin_api.dart';
import '../data/models/models.dart';
import '../features/memory/utils/memory_certainty.dart';
import 'api_provider.dart';

/// Owns the user memory twin for the Memory page. Reads via [IMemoryTwinApi],
/// deletes optimistically (prunes the local twin first; on server error,
/// re-fetches to restore truth).
class MemoryTwinNotifier extends AsyncNotifier<MemoryTwinResponse> {
  late IMemoryTwinApi _api;

  @override
  Future<MemoryTwinResponse> build() async {
    _api = ref.watch(memoryTwinApiProvider);
    return _api.getTwin();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_api.getTwin);
  }

  /// Re-fetch WITHOUT a loading state: the current chips stay on screen and are
  /// swapped when fresh data arrives. Used on Memory-page entry so it reflects
  /// activity (saves, views, new zines) instantly without a blank reload. On
  /// transient failure the last good twin is kept.
  Future<void> silentRefresh() async {
    try {
      state = AsyncData(await _api.getTwin());
    } catch (_) {
      // Keep the last good twin; a transient fetch error shouldn't blank the page.
    }
  }

  /// "Conta-nos sobre ti": submit a free-text self-description. On success the
  /// backend writes user_stated facts immediately, so we silently re-fetch the
  /// twin to surface them inline. Returns the outcome so the caller can show a
  /// confirmation (or an "we couldn't find anything to add" hint).
  Future<TellUsResult> tellUs(String text) async {
    final result = await _api.tellUs(text);
    // 'duplicate' means an EARLIER identical submission was accepted — its
    // facts may already be live while this tab never refreshed (seen live:
    // a retried submit told the user "nothing new" while the chips from
    // the first attempt only appeared after an app restart).
    if (result.applied || result.status == 'duplicate') {
      await silentRefresh();
    }
    return result;
  }

  Future<void> deleteObservation(String observationId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(_pruneByObservation(current, observationId));
    try {
      await _api.deleteObservation(observationId);
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  /// Deletes a chip by **suppressing** just its (dimension, value) — the
  /// backing facts stay, so the saved item in "Your collection" and the chip's
  /// sibling chips (a saved venue also feeds cuisine / amenities chips) are
  /// untouched. The chip vanishes in one tap.
  Future<void> suppressChip(
    DimensionView dimension,
    ObservationView observation,
  ) async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(
      _pruneByValue(current, dimension.name, observation.value),
    );
    try {
      await _api.suppressChip(
        dimension: dimension.name,
        family: dimension.family,
        value: observation.value,
      );
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  /// Manual − / + on a chip's tick level. Updates the meter **optimistically
  /// and in place** — no loading state, no re-fetch — so the bar moves
  /// instantly and the page never blanks or collapses. The server call
  /// persists the (decaying) nudge in the background; only on failure do we
  /// re-fetch to restore truth.
  Future<void> nudgeChip(
    DimensionView dimension,
    ObservationView observation, {
    required bool increase,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final currentTicks = certaintyTicks(observation.certainty);
    // 1..5: the top slot is the user's pin (a "+" on a level-4 chip) — the
    // old clamp at 4 swallowed exactly that tap: the bar never moved even
    // though the server stored the pin.
    final targetTicks = (currentTicks + (increase ? 1 : -1)).clamp(1, 5);
    if (targetTicks != currentTicks) {
      state = AsyncData(
        _bumpValueCertainty(
          current,
          dimension.name,
          observation.value,
          ticksToCertainty(targetTicks),
        ),
      );
    }
    try {
      await _api.nudgeChip(
        dimension: dimension.name,
        family: dimension.family,
        value: observation.value,
        increase: increase,
      );
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  Future<void> deleteFact(String factId) async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(_pruneByFact(current, factId));
    try {
      await _api.deleteFact(factId);
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  Future<void> deleteDimension(String dimensionName) async {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(_pruneByDimension(current, dimensionName));
    try {
      await _api.deleteDimension(dimensionName);
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  /// Convenience: deletes every dimension in a family. Used by the
  /// per-family "Clear category" affordance.
  Future<void> deleteFamily(String familyName) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final dimNames = current.families
        .firstWhere(
          (f) => f.family == familyName,
          orElse: () => const FamilyView(family: '', dimensions: []),
        )
        .dimensions
        .map((d) => d.name)
        .toList(growable: false);
    if (dimNames.isEmpty) return;
    state = AsyncData(_pruneByFamily(current, familyName));
    try {
      // Serialized so a mid-stream failure stops the cascade instead of
      // racing N parallel deletes whose subexceptions get swallowed.
      for (final name in dimNames) {
        await _api.deleteDimension(name);
      }
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  Future<BulkClearResponse> clearAll() async {
    final result = await _api.clearAll();
    await refresh();
    return result;
  }

  Future<List<int>> exportJson() => _api.exportJson();

  // ----- pure pruners -----

  MemoryTwinResponse _pruneByObservation(
    MemoryTwinResponse twin,
    String observationId,
  ) => _prune(twin, (o) => o.id == observationId);

  MemoryTwinResponse _pruneByFact(MemoryTwinResponse twin, String factId) =>
      _prune(twin, (o) => o.backingFacts.any((f) => f.id == factId));

  /// Optimistically drop one chip: observations whose value matches, but only
  /// inside the named dimension (sibling chips in other dimensions stay).
  MemoryTwinResponse _pruneByValue(
    MemoryTwinResponse twin,
    String dimensionName,
    String value,
  ) {
    final target = value.toLowerCase();
    final families = <FamilyView>[];
    for (final family in twin.families) {
      final dims = <DimensionView>[];
      for (final dim in family.dimensions) {
        final obs = dim.name == dimensionName
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
        families.add(FamilyView(family: family.family, dimensions: dims));
      }
    }
    return _withFamilies(twin, families);
  }

  /// Optimistic − / + : replace the certainty of every observation matching
  /// `(dimensionName, value)` so the tick meter jumps a whole bar in place.
  /// The observation `id` is preserved, so the expanded panel stays open and
  /// no parent section collapses.
  MemoryTwinResponse _bumpValueCertainty(
    MemoryTwinResponse twin,
    String dimensionName,
    String value,
    double newCertainty,
  ) {
    final target = value.toLowerCase();
    final families = <FamilyView>[];
    for (final family in twin.families) {
      final dims = <DimensionView>[];
      for (final dim in family.dimensions) {
        if (dim.name != dimensionName) {
          dims.add(dim);
          continue;
        }
        final obs = dim.observations
            .map(
              (o) => o.value.toLowerCase() == target
                  ? _withCertainty(o, newCertainty)
                  : o,
            )
            .toList(growable: false);
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
      families.add(FamilyView(family: family.family, dimensions: dims));
    }
    return _withFamilies(twin, families);
  }

  ObservationView _withCertainty(ObservationView o, double certainty) =>
      ObservationView(
        id: o.id,
        value: o.value,
        certainty: certainty,
        polarity: o.polarity,
        strength: o.strength,
        sourceClass: o.sourceClass,
        uses: o.uses,
        canDelete: o.canDelete,
        backingFacts: o.backingFacts,
        provenanceKind: o.provenanceKind,
        provenanceKinds: o.provenanceKinds,
        observedAt: o.observedAt,
        sourceFactId: o.sourceFactId,
        sourceSessionId: o.sourceSessionId,
        factSource: o.factSource,
        evidenceText: o.evidenceText,
        // 2026-09-09: these two were dropped by the copy, so a nudged
        // venue_type chip lost its category group and was re-routed to a
        // different parent section on the next rebuild — the chip
        // "disappeared" from under the user's finger.
        group: o.group,
        tier: o.tier,
      );

  MemoryTwinResponse _pruneByDimension(
    MemoryTwinResponse twin,
    String dimensionName,
  ) {
    final families = <FamilyView>[];
    for (final family in twin.families) {
      final dims = family.dimensions
          .where((d) => d.name != dimensionName)
          .toList(growable: false);
      if (dims.isNotEmpty) {
        families.add(FamilyView(family: family.family, dimensions: dims));
      }
    }
    return _withFamilies(twin, families);
  }

  MemoryTwinResponse _pruneByFamily(
    MemoryTwinResponse twin,
    String familyName,
  ) {
    final families = twin.families
        .where((f) => f.family != familyName)
        .toList(growable: false);
    return _withFamilies(twin, families);
  }

  MemoryTwinResponse _prune(
    MemoryTwinResponse twin,
    bool Function(ObservationView) predicate,
  ) {
    final families = <FamilyView>[];
    for (final family in twin.families) {
      final dims = <DimensionView>[];
      for (final dim in family.dimensions) {
        final obs = dim.observations
            .where((o) => !predicate(o))
            .toList(growable: false);
        if (obs.isNotEmpty) {
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
        families.add(FamilyView(family: family.family, dimensions: dims));
      }
    }
    return _withFamilies(twin, families);
  }

  MemoryTwinResponse _withFamilies(
    MemoryTwinResponse twin,
    List<FamilyView> families,
  ) => MemoryTwinResponse(
    userProfileId: twin.userProfileId,
    schemaVersion: twin.schemaVersion,
    policyVersion: twin.policyVersion,
    projectorVersion: twin.projectorVersion,
    taxonomyVersion: twin.taxonomyVersion,
    personaTags: twin.personaTags,
    families: families,
    actionFacts: twin.actionFacts,
    generatedAt: twin.generatedAt,
  );
}

final memoryTwinProvider =
    AsyncNotifierProvider<MemoryTwinNotifier, MemoryTwinResponse>(
      MemoryTwinNotifier.new,
    );
