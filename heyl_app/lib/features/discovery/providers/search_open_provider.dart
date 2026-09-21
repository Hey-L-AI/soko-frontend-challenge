import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the Discovery search panel (collapsed action bar with full-width
/// search input + category tabs) is currently open. When true, the chat ask
/// card hides; when false, both the chat card and the idle action bar render.
///
/// Lives at the page level (not inside the action bar widget) so the chat
/// bar can react without prop drilling.
final searchOpenProvider = StateProvider<bool>((ref) => false);
