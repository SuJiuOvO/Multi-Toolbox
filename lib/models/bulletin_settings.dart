import 'dart:convert';

/// User editable display settings; corrupted or older saved values are normalized.
class BulletinSettings {
  final String text;
  final double fontSize;
  final double speed;
  final double letterSpacing;
  final double lineHeight;
  final int textColor;
  final int backgroundColor;
  final bool bold;
  final bool glow;
  final bool stroke;
  final bool led;
  final bool mirror;
  final bool flash;
  final double flashPeriod;
  final int quarterTurns;
  final String direction;
  final bool landscape;

  const BulletinSettings({
    this.text = '很高兴遇见你！',
    this.fontSize = 112,
    this.speed = 100,
    this.letterSpacing = 3,
    this.lineHeight = 1.2,
    this.textColor = 0xFF53FFAA,
    this.backgroundColor = 0xFF080D12,
    this.bold = true,
    this.glow = true,
    this.stroke = false,
    this.led = false,
    this.mirror = false,
    this.flash = false,
    this.flashPeriod = 1.5,
    this.quarterTurns = 0,
    this.direction = 'left',
    this.landscape = true,
  });

  static const directions = ['still', 'left', 'right', 'up', 'down'];

  BulletinSettings copyWith({
    String? text,
    double? fontSize,
    double? speed,
    double? letterSpacing,
    double? lineHeight,
    int? textColor,
    int? backgroundColor,
    bool? bold,
    bool? glow,
    bool? stroke,
    bool? led,
    bool? mirror,
    bool? flash,
    double? flashPeriod,
    int? quarterTurns,
    String? direction,
    bool? landscape,
  }) =>
      BulletinSettings(
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        speed: speed ?? this.speed,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        lineHeight: lineHeight ?? this.lineHeight,
        textColor: textColor ?? this.textColor,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        bold: bold ?? this.bold,
        glow: glow ?? this.glow,
        stroke: stroke ?? this.stroke,
        led: led ?? this.led,
        mirror: mirror ?? this.mirror,
        flash: flash ?? this.flash,
        flashPeriod: flashPeriod ?? this.flashPeriod,
        quarterTurns: quarterTurns ?? this.quarterTurns,
        direction: direction ?? this.direction,
        landscape: landscape ?? this.landscape,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'fontSize': fontSize,
        'speed': speed,
        'letterSpacing': letterSpacing,
        'lineHeight': lineHeight,
        'textColor': textColor,
        'backgroundColor': backgroundColor,
        'bold': bold,
        'glow': glow,
        'stroke': stroke,
        'led': led,
        'mirror': mirror,
        'flash': flash,
        'flashPeriod': flashPeriod,
        'quarterTurns': quarterTurns,
        'direction': direction,
        'landscape': landscape,
      };

  factory BulletinSettings.fromJson(Map<String, dynamic> value) {
    const fallback = BulletinSettings();
    double number(String key, double defaultValue, double min, double max) {
      final input = value[key];
      final parsed =
          input is num ? input.toDouble() : double.tryParse('$input');
      return parsed != null && parsed.isFinite
          ? parsed.clamp(min, max).toDouble()
          : defaultValue;
    }

    int color(String key, int defaultValue) {
      final input = value[key];
      return input is int && input >= 0 && input <= 0xFFFFFFFF
          ? (input | 0xFF000000)
          : defaultValue;
    }

    bool flag(String key, bool defaultValue) =>
        value[key] is bool ? value[key] as bool : defaultValue;
    final rawText = value['text'];
    return BulletinSettings(
      text: rawText is String
          ? rawText.substring(0, rawText.length.clamp(0, 2000))
          : fallback.text,
      fontSize: number('fontSize', fallback.fontSize, 24, 320),
      speed: number('speed', fallback.speed, 10, 500),
      letterSpacing: number('letterSpacing', fallback.letterSpacing, -2, 30),
      lineHeight: number('lineHeight', fallback.lineHeight, 1, 2),
      textColor: color('textColor', fallback.textColor),
      backgroundColor: color('backgroundColor', fallback.backgroundColor),
      bold: flag('bold', fallback.bold),
      glow: flag('glow', fallback.glow),
      stroke: flag('stroke', fallback.stroke),
      led: flag('led', fallback.led),
      mirror: flag('mirror', fallback.mirror),
      flash: flag('flash', fallback.flash),
      flashPeriod: number('flashPeriod', fallback.flashPeriod, 1, 5),
      quarterTurns: number('quarterTurns', 0, 0, 3).round(),
      direction: directions.contains(value['direction'])
          ? value['direction'] as String
          : fallback.direction,
      landscape: flag('landscape', fallback.landscape),
    );
  }

  static BulletinSettings decode(String? source) {
    try {
      final value = source == null ? null : jsonDecode(source);
      return value is Map<String, dynamic>
          ? BulletinSettings.fromJson(value)
          : const BulletinSettings();
    } on FormatException {
      return const BulletinSettings();
    }
  }

  static const presets = <String, BulletinSettings>{
    '霓虹应援': BulletinSettings(),
    '接机举牌': BulletinSettings(
      text: '欢迎回家',
      direction: 'still',
      textColor: 0xFFFFFFFF,
      backgroundColor: 0xFF134E4A,
      glow: false,
      fontSize: 148,
    ),
    '像素夜色': BulletinSettings(
      text: 'HELLO WORLD',
      textColor: 0xFFFFB547,
      backgroundColor: 0xFF101017,
      led: true,
      glow: false,
    ),
    '告白粉': BulletinSettings(
      text: '今天也喜欢你 ♡',
      textColor: 0xFFFF75C8,
      backgroundColor: 0xFF210F24,
      speed: 70,
      fontSize: 128,
    ),
  };
}
