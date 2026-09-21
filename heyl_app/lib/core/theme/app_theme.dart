import 'package:flutter/material.dart';
import 'app_colors.dart';

/// App theme configuration for Soko
/// Updated to use Zalando Sans font (January 2025)
class AppTheme {
  AppTheme._();

  // Font family constants - Zalando Sans for both display and body (matches Lovable mockup)
  static const String _displayFontFamily = 'ZalandoSans';
  static const String _bodyFontFamily = 'ZalandoSans';

  // Editorial display family — currently scoped to Discovery H1 surfaces only.
  // Don't pull this into [display] wholesale; many call sites depend on the
  // Zalando metrics (line-height, optical size).
  static const String _displayPrimaryFontFamily = 'SeasonMix';

  // Letter spacing constants (matching Lovable)
  static const double _displayLetterSpacing = -0.02;
  static const double _bodyLetterSpacing = -0.01;

  /// Display text style (Zalando Sans) - for hero text, page titles, bold headings
  /// Matches Lovable's font-display class with -0.02em letter spacing
  static TextStyle display({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w700,
    Color? color,
    double? height,
  }) {
    return TextStyle(
      fontFamily: _displayFontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: fontSize * _displayLetterSpacing,
      height: height,
      color: color,
    );
  }

  /// Editorial display style (Season Mix TRIAL) — for the H1 surfaces
  /// specced in the Discovery Figma cut: shelf titles ("Tuas", "Em destaque"…)
  /// and the end-of-page footer. Letter-spacing defaults to the same -2% the
  /// Zalando display uses; pass [letterSpacing] to override.
  static TextStyle displayPrimary({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w300,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: _displayPrimaryFontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing ?? fontSize * _displayLetterSpacing,
      height: height,
      color: color,
    );
  }

  /// Body text style (Zalando Sans) - for regular text, labels
  /// Matches Lovable's font-sans class with -0.01em letter spacing
  static TextStyle body({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
  }) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: fontSize * _bodyLetterSpacing,
      height: height,
      color: color,
    );
  }

  // ============================================
  // LOVABLE TYPOGRAPHY HELPERS (from PDF specs)
  // ============================================

  /// Page title style (MEMORIES, LISTS, CIRCLES)
  /// Font: Zalando Sans, 20px, Bold 700, uppercase, tracking-wider (0.05em)
  static TextStyle pageTitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.0, // 20 * 0.05 = tracking-wider
      color: color,
    );
  }

  /// Section title style (By you, Following, Recommended for you)
  /// Font: Zalando Sans, 20px, Regular 400
  static TextStyle sectionTitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 20,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }

  /// Subtitle style (Summary, Here's what I know about you)
  /// Font: Zalando Sans, 16px, Semibold 600 or Medium 500
  static TextStyle subtitle({
    Color? color,
    FontWeight fontWeight = FontWeight.w600,
  }) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 16,
      fontWeight: fontWeight,
      color: color,
    );
  }

  /// Card title style (list card titles - Best brunch spots)
  /// Font: Zalando Sans, 15px, Regular 400, leading-snug
  static TextStyle cardTitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.375, // leading-snug
      color: color,
    );
  }

  /// Card author/subtitle style (You, Soko)
  /// Font: Zalando Sans, 12px, Regular 400, 60% opacity
  static TextStyle cardAuthor({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: color?.withValues(alpha: 0.6),
    );
  }

  /// List item title style (in ListElementCard)
  /// Font: Zalando Sans, 17px, Regular 400
  static TextStyle listItemTitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 17,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }

  /// List item subtitle style (description, location)
  /// Font: Zalando Sans, 12px, Regular 400, 70% opacity
  static TextStyle listItemSubtitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: color?.withValues(alpha: 0.7),
    );
  }

  /// **Mobile/B1 Reg** per Soko design tokens — Zalando Sans Light,
  /// 18 px, line-height 1.0, letterSpacing -0.36 px. Used as the body
  /// text on the redesigned list page (`list_view_item_row.dart`) and
  /// will be reused by the Zine view body (PROD-1703).
  ///
  /// Distinct from [listItemTitle] (legacy 17 px / w400) — do not swap
  /// them.
  static TextStyle mobileB1Reg({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 18,
      fontWeight: FontWeight.w300,
      height: 1.0,
      letterSpacing: -0.36,
      color: color,
    );
  }

  /// **Mobile/H2** — Season Mix TRIAL 32, line-height 1.0, tracking 0.
  /// The page title on the new library screens (Figma `7598:26026` and its
  /// four siblings, all 214 x 32).
  ///
  /// Tracking is explicitly **0**, not the -2 % [displayPrimary] defaults to.
  static TextStyle mobileH2({Color? color}) {
    return displayPrimary(
      fontSize: 32,
      fontWeight: FontWeight.w400,
      height: 1.0,
      letterSpacing: 0,
      color: color,
    );
  }

  /// **Mobile/H3** — Season Mix TRIAL 26, line-height 1.0, tracking 0.
  /// The empty-state heading on the library screens, which wraps to two lines
  /// (the Figma text box is 52 tall = 2 x 26).
  static TextStyle mobileH3({Color? color}) {
    return displayPrimary(
      fontSize: 26,
      fontWeight: FontWeight.w400,
      height: 1.0,
      letterSpacing: 0,
      color: color,
    );
  }

  /// **Mobile/B2 Reg** per Soko design tokens — Zalando Sans Light,
  /// 14 px, line-height 1.0, letterSpacing -0.14 px. Sub-line / muted
  /// body. Pair with [AppColors.sokoShade4] for the canonical muted
  /// colour. Distinct from [listItemSubtitle] (legacy 12 px / w400).
  static TextStyle mobileB2Reg({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w300,
      height: 1.0,
      letterSpacing: -0.14,
      color: color,
    );
  }

  /// List detail header title style
  /// Font: Zalando Sans, 18px, Regular 400
  static TextStyle listDetailTitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 18,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }

  /// Hub subtitle style (ANJOS, ALVALADE)
  /// Font: Zalando Sans, 14px, Bold 700
  static TextStyle hubSubtitle({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: color,
    );
  }

  /// Hub description style (Your neighbourhood)
  /// Font: Zalando Sans, 12px, Regular 400
  static TextStyle hubDescription({Color? color}) {
    return TextStyle(
      fontFamily: _bodyFontFamily,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }

  /// Light theme
  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: _bodyFontFamily,
      colorScheme: ColorScheme.light(
        primary: AppColors.primary,
        onPrimary: AppColors.textOnPrimary,
        secondary: AppColors.secondary,
        onSecondary: AppColors.secondaryForeground,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.error,
        onError: AppColors.textOnPrimary,
      ),
      scaffoldBackgroundColor: AppColors.background,
      textTheme: _textTheme(isLight: true),
      appBarTheme: _appBarTheme(isLight: true),
      elevatedButtonTheme: _elevatedButtonTheme,
      outlinedButtonTheme: _outlinedButtonTheme,
      textButtonTheme: _textButtonTheme,
      inputDecorationTheme: _inputDecorationTheme(isLight: true),
      cardTheme: _cardTheme(isLight: true),
      bottomNavigationBarTheme: _bottomNavTheme(isLight: true),
      dividerTheme: _dividerTheme(isLight: true),
      chipTheme: _chipTheme(isLight: true),
    );
  }

  /// Dark theme
  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: _bodyFontFamily,
      colorScheme: ColorScheme.dark(
        primary: AppColors.primaryDarkMode,
        onPrimary: AppColors.textOnPrimary,
        secondary: AppColors.surfaceVariantDark,
        onSecondary: AppColors.textPrimaryDark,
        surface: AppColors.surfaceDark,
        onSurface: AppColors.textPrimaryDark,
        error: AppColors.error,
        onError: AppColors.textOnPrimary,
      ),
      scaffoldBackgroundColor: AppColors.backgroundDark,
      textTheme: _textTheme(isLight: false),
      appBarTheme: _appBarTheme(isLight: false),
      elevatedButtonTheme: _elevatedButtonThemeDark,
      outlinedButtonTheme: _outlinedButtonThemeDark,
      textButtonTheme: _textButtonThemeDark,
      inputDecorationTheme: _inputDecorationTheme(isLight: false),
      cardTheme: _cardTheme(isLight: false),
      bottomNavigationBarTheme: _bottomNavTheme(isLight: false),
      dividerTheme: _dividerTheme(isLight: false),
      chipTheme: _chipTheme(isLight: false),
    );
  }

  // Typography: Zalando Sans for both headings and body (matches Lovable mockup)
  static TextTheme _textTheme({required bool isLight}) {
    final textPrimary = isLight
        ? AppColors.textPrimary
        : AppColors.textPrimaryDark;
    final textSecondary = isLight
        ? AppColors.textSecondary
        : AppColors.textSecondaryDark;
    final textTertiary = isLight
        ? AppColors.textTertiary
        : AppColors.textTertiaryDark;

    return TextTheme(
      // Display styles - Zalando Sans with tight letter spacing
      displayLarge: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 32,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.64, // -0.02em
        color: textPrimary,
      ),
      displayMedium: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 28,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.56, // -0.02em
        color: textPrimary,
      ),
      displaySmall: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.48, // -0.02em
        color: textPrimary,
      ),
      // Headline styles - Zalando Sans
      headlineLarge: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.44, // -0.02em
        color: textPrimary,
      ),
      headlineMedium: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4, // -0.02em
        color: textPrimary,
      ),
      headlineSmall: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.36, // -0.02em
        color: textPrimary,
      ),
      // Title styles - Zalando Sans (semi-bold)
      titleLarge: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.32, // -0.02em
        color: textPrimary,
      ),
      titleMedium: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.28, // -0.02em
        color: textPrimary,
      ),
      titleSmall: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.24, // -0.02em
        color: textPrimary,
      ),
      // Body styles - Zalando Sans with subtle letter spacing
      bodyLarge: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.16, // -0.01em
        color: textPrimary,
      ),
      bodyMedium: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.14, // -0.01em
        color: textPrimary,
      ),
      bodySmall: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.12, // -0.01em
        color: textSecondary,
      ),
      // Label styles - Zalando Sans
      labelLarge: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.14, // -0.01em
        color: textPrimary,
      ),
      labelMedium: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.12, // -0.01em
        color: textSecondary,
      ),
      labelSmall: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 10,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.1, // -0.01em
        color: textTertiary,
      ),
    );
  }

  static AppBarTheme _appBarTheme({required bool isLight}) {
    final bgColor = isLight ? AppColors.surface : AppColors.surfaceDark;
    final fgColor = isLight ? AppColors.textPrimary : AppColors.textPrimaryDark;

    return AppBarTheme(
      backgroundColor: bgColor,
      foregroundColor: fgColor,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: _displayFontFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.36,
        color: fgColor,
      ),
    );
  }

  // Light mode button themes
  static ElevatedButtonThemeData get _elevatedButtonTheme {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textOnPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: _bodyFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.14,
        ),
      ),
    );
  }

  static OutlinedButtonThemeData get _outlinedButtonTheme {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        side: const BorderSide(color: AppColors.primary),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: _bodyFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.14,
        ),
      ),
    );
  }

  static TextButtonThemeData get _textButtonTheme {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        textStyle: const TextStyle(
          fontFamily: _bodyFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.14,
        ),
      ),
    );
  }

  // Dark mode button themes
  static ElevatedButtonThemeData get _elevatedButtonThemeDark {
    return ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primaryDarkMode,
        foregroundColor: AppColors.textOnPrimary,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: _bodyFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.14,
        ),
      ),
    );
  }

  static OutlinedButtonThemeData get _outlinedButtonThemeDark {
    return OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primaryDarkMode,
        side: const BorderSide(color: AppColors.primaryDarkMode),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontFamily: _bodyFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.14,
        ),
      ),
    );
  }

  static TextButtonThemeData get _textButtonThemeDark {
    return TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primaryDarkMode,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        textStyle: const TextStyle(
          fontFamily: _bodyFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.14,
        ),
      ),
    );
  }

  static InputDecorationTheme _inputDecorationTheme({required bool isLight}) {
    final fillColor = isLight ? AppColors.surface : AppColors.surfaceDark;
    final borderColor = isLight ? AppColors.border : AppColors.borderDarkMode;
    final primaryColor = isLight
        ? AppColors.primary
        : AppColors.primaryDarkMode;
    final hintColor = isLight
        ? AppColors.textTertiary
        : AppColors.textTertiaryDark;

    return InputDecorationTheme(
      filled: true,
      fillColor: fillColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: primaryColor, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      hintStyle: TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 14,
        letterSpacing: -0.14,
        color: hintColor,
      ),
    );
  }

  static CardThemeData _cardTheme({required bool isLight}) {
    final cardColor = isLight ? AppColors.surface : AppColors.surfaceDark;
    final borderColor = isLight ? AppColors.border : AppColors.borderDarkMode;

    return CardThemeData(
      color: cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20), // 1.25rem from Lovable
        side: BorderSide(color: borderColor),
      ),
    );
  }

  static BottomNavigationBarThemeData _bottomNavTheme({required bool isLight}) {
    final bgColor = isLight ? AppColors.surface : AppColors.surfaceDark;
    final selectedColor = isLight
        ? AppColors.primary
        : AppColors.primaryDarkMode;
    final unselectedColor = isLight
        ? AppColors.textTertiary
        : AppColors.textTertiaryDark;

    return BottomNavigationBarThemeData(
      backgroundColor: bgColor,
      selectedItemColor: selectedColor,
      unselectedItemColor: unselectedColor,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    );
  }

  static DividerThemeData _dividerTheme({required bool isLight}) {
    final dividerColor = isLight ? AppColors.border : AppColors.borderDarkMode;

    return DividerThemeData(color: dividerColor, thickness: 1, space: 1);
  }

  static ChipThemeData _chipTheme({required bool isLight}) {
    final bgColor = isLight ? AppColors.surface : AppColors.surfaceDark;
    final primaryColor = isLight
        ? AppColors.primary
        : AppColors.primaryDarkMode;
    final borderColor = isLight ? AppColors.border : AppColors.borderDarkMode;

    return ChipThemeData(
      backgroundColor: bgColor,
      selectedColor: primaryColor.withValues(alpha: 0.1),
      side: BorderSide(color: borderColor),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: const TextStyle(
        fontFamily: _bodyFontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.14,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    );
  }
}
