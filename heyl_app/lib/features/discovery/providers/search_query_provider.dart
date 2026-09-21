import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Debounced search query typed into the Discovery action bar. The
/// `TextEditingController` inside `DiscoverySearchOverlay` drives the
/// input directly; this provider only updates after a 600 ms debounce so
/// result fetches don't fire on every keystroke.
///
/// Empty (or whitespace-only) means "no active search" — `SearchResultsSection`
/// reads that to short-circuit and let the existing shelves render.
final searchQueryProvider = StateProvider<String>((ref) => '');
