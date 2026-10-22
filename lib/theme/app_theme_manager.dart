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
  static const List<AppThemeOption> options = [
    AppThemeOption(
      id: 'tech_blue',
      name: '科技蔚蓝',
      description: '经典纯净科技蓝，高雅大气且清爽干练',
      icon: Icons.water_drop_rounded,
      primaryColor: Color(0xFF2563EB),
      secondaryColor: Color(0xFF38BDF8),
      previewBackground: Color(0xFFF8FAFC),
    ),
    AppThemeOption(
      id: 'obsidian_aurora',
      name: '黑曜极光',
      description: '极客纯黑与夜空霓虹紫蓝，极致护眼沉浸',
      icon: Icons.nightlight_round,
      primaryColor: Color(0xFF818CF8),
      secondaryColor: Color(0xFFA855F7),
      previewBackground: Color(0xFF0F172A),
      isDark: true,
    ),
    AppThemeOption(
      id: 'forest_emerald',
      name: '晨曦青翠',
      description: '自然生机墨绿与薄荷青，清新柔和舒适',
      icon: Icons.eco_rounded,
      primaryColor: Color(0xFF059669),
      secondaryColor: Color(0xFF34D399),
      previewBackground: Color(0xFFF4FBF7),
    ),
    AppThemeOption(
      id: 'sunset_coral',
      name: '暮光暖橘',
      description: '温润落日珊瑚与活力暖橙，优雅生动',
      icon: Icons.wb_sunny_rounded,
      primaryColor: Color(0xFFEA580C),
      secondaryColor: Color(0xFFFB923C),
      previewBackground: Color(0xFFFFF9F5),
    ),
    AppThemeOption(
      id: 'liquid_glass',
      name: '液态晶透',
      description: '拟物晶莹毛玻璃美学，通透微光与亚克力质感',
      icon: Icons.blur_on_rounded,
      primaryColor: Color(0xFF0284C7),
      secondaryColor: Color(0xFF38BDF8),
      previewBackground: Color(0xFFEFF6FF),
      isGlass: true,
    ),
  ];

  static AppThemeOption getOption(String id) {
    return options.firstWhere((o) => o.id == id, orElse: () => options.first);
  }

  static ThemeData getThemeData(String id) {
    final option = getOption(id);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: option.primaryColor,
      brightness: option.isDark ? Brightness.dark : Brightness.light,
      primary: option.primaryColor,
    );

    if (option.isDark) {
      return ThemeData(
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        cardColor: const Color(0xFF1E293B),
        cardTheme: CardThemeData(
          color: const Color(0xFF1E293B),
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF334155), width: 0.8),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1120),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
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
      return ThemeData(
        brightness: Brightness.light,
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF1F5F9),
        cardColor: Colors.white.withValues(alpha: 0.85),
        cardTheme: CardThemeData(
          color: Colors.white.withValues(alpha: 0.88),
          elevation: 1.5,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.8), width: 1.2),
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.white.withValues(alpha: 0.75),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        fontFamilyFallback: const [
          'PingFang SC',
          'Microsoft YaHei',
          'Noto Sans SC',
          'sans-serif',
        ],
      );
    }

    // Standard light themes (Tech blue, Forest emerald, Sunset coral)
    return ThemeData(
      brightness: Brightness.light,
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: option.previewBackground,
      cardColor: Colors.white,
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0.8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200, width: 0.8),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: option.previewBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
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
