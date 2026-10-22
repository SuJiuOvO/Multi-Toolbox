import 'package:flutter/material.dart';

class AppThemeOption {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color primaryColor;
  final Color secondaryColor;
  final Color previewBackground;
  final bool isDark;
  final bool isGlass;

  const AppThemeOption({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.primaryColor,
    required this.secondaryColor,
    required this.previewBackground,
    this.isDark = false,
    this.isGlass = false,
  });
}

class AppThemeManager {
  // 次色调通用定义：蓝、绿、黄、红
  static const Color accentBlue = Color(0xFF2563EB);
  static const Color accentGreen = Color(0xFF10B981);
  static const Color accentYellow = Color(0xFFF59E0B);
  static const Color accentRed = Color(0xFFEF4444);

  static const List<AppThemeOption> options = [
    AppThemeOption(
      id: 'minimal_clean',
      name: '简约黑白灰',
      description: '主色黑白灰极简耐看，高对比度清晰分明，配蓝绿黄红次色调',
      icon: Icons.contrast_rounded,
      primaryColor: Color(0xFF111827),
      secondaryColor: Color(0xFF2563EB),
      previewBackground: Color(0xFFF9FAFB),
    ),
    AppThemeOption(
      id: 'liquid_glass',
      name: '液态晶透',
      description: '真实毛玻璃模糊晶体美学，半透明微光边框与灵动光晕',
      icon: Icons.blur_on_rounded,
      primaryColor: Color(0xFF0F172A),
      secondaryColor: Color(0xFF0284C7),
      previewBackground: Color(0xFFEEF2F6),
      isGlass: true,
    ),
    AppThemeOption(
      id: 'obsidian_aurora',
      name: '黑曜极光',
      description: '纯黑深邃护眼底色，纯白高对比度文字与极光霓虹点缀',
      icon: Icons.nightlight_round,
      primaryColor: Color(0xFF818CF8),
      secondaryColor: Color(0xFFA855F7),
      previewBackground: Color(0xFF0B1120),
      isDark: true,
    ),
    AppThemeOption(
      id: 'tech_blue',
      name: '科技蔚蓝',
      description: '经典科技深蓝，高对比度清爽干练',
      icon: Icons.water_drop_rounded,
      primaryColor: Color(0xFF1D4ED8),
      secondaryColor: Color(0xFF38BDF8),
      previewBackground: Color(0xFFF8FAFC),
    ),
    AppThemeOption(
      id: 'forest_emerald',
      name: '晨曦青翠',
      description: '自然生机墨绿，雅致护眼高对比度',
      icon: Icons.eco_rounded,
      primaryColor: Color(0xFF047857),
      secondaryColor: Color(0xFF10B981),
      previewBackground: Color(0xFFF4FBF7),
    ),
    AppThemeOption(
      id: 'sunset_coral',
      name: '暮光暖橘',
      description: '温润落日珊瑚与金秋活力暖色',
      icon: Icons.wb_sunny_rounded,
      primaryColor: Color(0xFFC2410C),
      secondaryColor: Color(0xFFF97316),
      previewBackground: Color(0xFFFFF9F5),
    ),
  ];

  static AppThemeOption getOption(String id) {
    return options.firstWhere((o) => o.id == id, orElse: () => options.first);
  }

  static ThemeData getThemeData(String id) {
    final option = getOption(id);

    if (option.isDark) {
      // 纯粹暗黑：纯黑底、纯白字、高对比度！
      const bg = Color(0xFF0B1120);
      const cardBg = Color(0xFF1E293B);
      const primary = Color(0xFF818CF8);

      return ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.dark(
          primary: primary,
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFF1E293B),
          onPrimaryContainer: const Color(0xFFF8FAFC),
          secondary: const Color(0xFF38BDF8),
          onSecondary: Colors.white,
          surface: cardBg,
          onSurface: const Color(0xFFF8FAFC), // 纯白高对比度文字
          onSurfaceVariant: const Color(0xFFCBD5E1), // 浅灰高对比度描述
          outline: const Color(0xFF475569),
          error: accentRed,
        ),
        useMaterial3: true,
        cardColor: cardBg,
        cardTheme: CardThemeData(
          color: cardBg,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF334155), width: 1.0),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E293B),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          labelStyle: const TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.bold, fontSize: 14),
          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF475569)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF475569)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: Color(0xFF818CF8), width: 1.5),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dividerColor: const Color(0xFF334155),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.bold),
          titleMedium: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.w600),
          titleSmall: TextStyle(color: Color(0xFFF8FAFC), fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(color: Color(0xFFF8FAFC)),
          bodyMedium: TextStyle(color: Color(0xFFCBD5E1)),
          bodySmall: TextStyle(color: Color(0xFF94A3B8)),
        ),
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'Noto Sans SC',
          'sans-serif',
        ],
      );
    }

    if (option.isGlass) {
      // 液态晶透毛玻璃：半透明表面 + 高对比度深色文本
      const primary = Color(0xFF0F172A);

      return ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        colorScheme: ColorScheme.light(
          primary: primary,
          onPrimary: Colors.white,
          primaryContainer: Colors.white.withValues(alpha: 0.85),
          onPrimaryContainer: const Color(0xFF0F172A),
          secondary: const Color(0xFF0284C7),
          onSecondary: Colors.white,
          surface: Colors.white.withValues(alpha: 0.78),
          onSurface: const Color(0xFF0F172A), // 纯黑高对比度
          onSurfaceVariant: const Color(0xFF334155), // 深灰高对比度
          outline: Colors.white.withValues(alpha: 0.8),
          error: accentRed,
        ),
        useMaterial3: true,
        cardColor: Colors.white.withValues(alpha: 0.82),
        cardTheme: CardThemeData(
          color: Colors.white.withValues(alpha: 0.82),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.9), width: 1.5),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.85),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          labelStyle: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 14),
          hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.9)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.9)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
            borderSide: BorderSide(color: Color(0xFF0284C7), width: 1.5),
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.white.withValues(alpha: 0.70),
          foregroundColor: const Color(0xFF0F172A),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        dividerColor: Colors.black.withValues(alpha: 0.08),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold),
          titleMedium: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.w600),
          titleSmall: TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(color: Color(0xFF0F172A)),
          bodyMedium: TextStyle(color: Color(0xFF334155)),
          bodySmall: TextStyle(color: Color(0xFF475569)),
        ),
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'Noto Sans SC',
          'sans-serif',
        ],
      );
    }

    // 默认极简黑白灰及浅色主题：严格保证黑白分明与极高对比度
    final primary = option.id == 'minimal_clean' ? const Color(0xFF111827) : option.primaryColor;
    final secondary = option.id == 'minimal_clean' ? accentBlue : option.secondaryColor;

    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: option.previewBackground,
      colorScheme: ColorScheme.light(
        primary: primary,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFF3F4F6),
        onPrimaryContainer: const Color(0xFF111827),
        secondary: secondary,
        onSecondary: Colors.white,
        secondaryContainer: secondary.withValues(alpha: 0.12),
        onSecondaryContainer: secondary,
        surface: Colors.white,
        onSurface: const Color(0xFF111827), // 纯黑 Charcoal，锐利清晰！
        onSurfaceVariant: const Color(0xFF374151), // 深灰 Slate，文字高对比度！
        outline: const Color(0xFFD1D5DB), // 干净清晰的边框
        error: accentRed,
      ),
      useMaterial3: true,
      cardColor: Colors.white,
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFE5E7EB), width: 1.0),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        labelStyle: const TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.bold, fontSize: 14),
        hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: accentBlue, width: 1.5),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: option.previewBackground,
        foregroundColor: const Color(0xFF111827),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      dividerColor: const Color(0xFFE5E7EB),
      textTheme: const TextTheme(
        titleLarge: TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.bold),
        titleMedium: TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: Color(0xFF111827), fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: Color(0xFF111827)),
        bodyMedium: TextStyle(color: Color(0xFF374151)),
        bodySmall: TextStyle(color: Color(0xFF4B5563)),
      ),
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei',
        'Noto Sans SC',
        'sans-serif',
      ],
    );
  }
}
