import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider for sidebar open/close state
final sidebarOpenProvider = StateProvider<bool>((ref) => false);
