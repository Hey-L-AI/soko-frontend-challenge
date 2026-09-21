import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/storage_service.dart';

/// Key for storing theme mode preference
const String _themeModeKey = 'theme_mode';

/// Notifier for managing app theme mode
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  final SharedPreferences _prefs;

  // Start with system mode, will resolve in _loadSavedThemeMode
  ThemeModeNotifier(this._prefs) : super(ThemeMode.system) {
    _loadSavedThemeMode();
  }

  void _loadSavedThemeMode() {
    final savedMode = _prefs.getString(_themeModeKey);
    if (savedMode != null) {
      // User has a saved preference - use it
      state = _themeModeFromString(savedMode);
    } else {
      // No saved preference - detect system brightness
      // Default to light if we can't detect (platformBrightness defaults to light)
      final platformBrightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      state = platformBrightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light;
    }
  }

  /// Set the theme mode
  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await _prefs.setString(_themeModeKey, _themeModeToString(mode));
  }

  /// Toggle between light and dark mode
  /// If currently system, will check actual brightness and toggle to opposite
  Future<void> toggleThemeMode(Brightness currentBrightness) async {
    if (state == ThemeMode.system) {
      // If system mode, toggle based on current actual brightness
      final newMode =
          currentBrightness == Brightness.light ? ThemeMode.dark : ThemeMode.light;
      await setThemeMode(newMode);
    } else if (state == ThemeMode.light) {
      await setThemeMode(ThemeMode.dark);
    } else {
      await setThemeMode(ThemeMode.light);
    }
  }

  /// Reset to system theme
  Future<void> resetToSystem() async {
    state = ThemeMode.system;
    await _prefs.remove(_themeModeKey);
  }

  ThemeMode _themeModeFromString(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        // Default to light mode if unrecognized value
        return ThemeMode.light;
    }
  }

  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

/// Provider for theme mode state
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return ThemeModeNotifier(prefs);
});

/// Provider that returns true if dark mode is currently active
final isDarkModeProvider = Provider<bool>((ref) {
  final themeMode = ref.watch(themeModeProvider);

  // For system mode, we can't determine here - the app widget handles it
  // This provider is mainly useful when we explicitly set light/dark
  return themeMode == ThemeMode.dark;
});
