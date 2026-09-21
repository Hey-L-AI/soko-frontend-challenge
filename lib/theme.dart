import 'package:flutter/material.dart';

abstract final class SokoColors {
  static const paper = Color(0xFFF9F0F0);
  static const ink = Color(0xFF44131D);
  static const pink = Color(0xFFFFB8CB);
  static const yellow = Color(0xFFF0F288);
  static const blue = Color(0xFF8BDFFF);
  static const green = Color(0xFFB0EF8B);
  static const lilac = Color(0xFFC588F2);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: SokoColors.ink,
    primary: SokoColors.ink,
    onPrimary: SokoColors.paper,
    surface: SokoColors.paper,
    onSurface: SokoColors.ink,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: SokoColors.paper,
    appBarTheme: const AppBarTheme(
      backgroundColor: SokoColors.paper,
      foregroundColor: SokoColors.ink,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: SokoColors.paper,
      indicatorColor: SokoColors.pink,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.6),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
