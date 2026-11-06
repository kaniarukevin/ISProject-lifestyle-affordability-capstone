import 'package:flutter/material.dart';

/// Tosha's colours beyond Material's colour scheme: the one lime highlight, the warning amber, the three
/// financial states and the fills used on cards. Read them with `AppColors.of(context)`.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.lime,
    required this.onLime,
    required this.warn,
    required this.warnBg,
    required this.field,
    required this.range,
    required this.muted,
    required this.nav,
    required this.navIcon,
    required this.stable,
    required this.strained,
    required this.critical,
  });

  final Color lime;
  final Color onLime;
  final Color warn;
  final Color warnBg;
  final Color field;
  final Color range;
  final Color muted;
  final Color nav;
  final Color navIcon;
  final Color stable;
  final Color strained;
  final Color critical;

  static const light = AppColors(
    lime: Color(0xFFD6F26B),
    onLime: Color(0xFF111111),
    warn: Color(0xFF8A4B00),
    warnBg: Color(0xFFFFF1D6),
    field: Color(0xFFF2F2EE),
    range: Color(0xFFECECE6),
    muted: Color(0xFF6B6B66),
    nav: Color(0xFF111111),
    navIcon: Color(0xFFBDBDB6),
    stable: Color(0xFFD6F26B),
    strained: Color(0xFFD9A54C),
    critical: Color(0xFF7A3E00),
  );

  static const dark = AppColors(
    lime: Color(0xFFD6F26B),
    onLime: Color(0xFF111111),
    warn: Color(0xFFF2B866),
    warnBg: Color(0xFF3A2A12),
    field: Color(0xFF262623),
    range: Color(0xFF33332F),
    muted: Color(0xFFA3A39B),
    nav: Color(0xFF262623),
    navIcon: Color(0xFFBDBDB6),
    stable: Color(0xFFD6F26B),
    strained: Color(0xFFD9A54C),
    critical: Color(0xFFE08A4A),
  );

  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>()!;

  @override
  AppColors copyWith({Color? lime, Color? warn}) => AppColors(
        lime: lime ?? this.lime,
        onLime: onLime,
        warn: warn ?? this.warn,
        warnBg: warnBg,
        field: field,
        range: range,
        muted: muted,
        nav: nav,
        navIcon: navIcon,
        stable: stable,
        strained: strained,
        critical: critical,
      );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      lime: l(lime, other.lime),
      onLime: l(onLime, other.onLime),
      warn: l(warn, other.warn),
      warnBg: l(warnBg, other.warnBg),
      field: l(field, other.field),
      range: l(range, other.range),
      muted: l(muted, other.muted),
      nav: l(nav, other.nav),
      navIcon: l(navIcon, other.navIcon),
      stable: l(stable, other.stable),
      strained: l(strained, other.strained),
      critical: l(critical, other.critical),
    );
  }
}

/// The light and dark themes, from the tokens agreed on the design canvas (6 Nov).
class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final c = isDark ? AppColors.dark : AppColors.light;
    final ink = isDark ? const Color(0xFFF4F4F0) : const Color(0xFF111111);
    final card = isDark ? const Color(0xFF1A1A18) : Colors.white;
    final page = isDark ? const Color(0xFF0B0B0A) : const Color(0xFFF2F2EE);

    final scheme = ColorScheme(
      brightness: b,
      primary: ink,
      onPrimary: isDark ? const Color(0xFF111111) : Colors.white,
      secondary: c.lime,
      onSecondary: c.onLime,
      tertiary: c.warn,
      onTertiary: isDark ? const Color(0xFF111111) : Colors.white,
      error: c.warn,
      onError: isDark ? const Color(0xFF111111) : Colors.white,
      surface: card,
      onSurface: ink,
      onSurfaceVariant: c.muted,
      surfaceContainerLowest: card,
      surfaceContainerLow: card,
      surfaceContainer: card,
      surfaceContainerHigh: c.field,
      surfaceContainerHighest: c.field,
      outline: isDark ? const Color(0xFF4A4A45) : const Color(0xFFD9D9D2),
      outlineVariant: isDark ? const Color(0xFF33332F) : const Color(0xFFEEEEE9),
    );

    // Plus Jakarta Sans is bundled in assets/fonts (SIL Open Font License), so it also works offline.
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: b, fontFamily: 'PlusJakartaSans');
    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);
    const pill = StadiumBorder();

    return base.copyWith(
      scaffoldBackgroundColor: page,
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      extensions: [c],
      appBarTheme: AppBarTheme(
        backgroundColor: page,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: pill,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: pill,
          minimumSize: const Size(48, 48),
          side: BorderSide(color: ink, width: 1.5),
          foregroundColor: ink,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: pill,
          minimumSize: const Size(44, 44),
          foregroundColor: ink,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(44, 44))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: ink, width: 1.5)),
        labelStyle: TextStyle(color: c.muted),
        hintStyle: TextStyle(color: c.muted),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: pill,
        side: BorderSide.none,
        backgroundColor: card,
        selectedColor: ink,
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        secondaryLabelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onPrimary),
        checkmarkColor: scheme.onPrimary,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: pill,
          side: BorderSide.none,
          backgroundColor: c.field,
          selectedBackgroundColor: ink,
          selectedForegroundColor: scheme.onPrimary,
          minimumSize: const Size(44, 44),
        ),
      ),
      listTileTheme: ListTileThemeData(
        minVerticalPadding: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        subtitleTextStyle: text.bodyMedium?.copyWith(color: c.muted),
        iconColor: ink,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: page,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF111111),
        contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: ink, linearTrackColor: c.range),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onLime : null),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.lime : null),
      ),
    );
  }
}
