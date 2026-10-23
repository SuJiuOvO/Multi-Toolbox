import 'dart:io';

/// 插件输入显示条件定义 (用于模式/选项切换时的联动隐藏显示)
class PluginInputCondition {
  final String field;
  final dynamic equals;
  final dynamic notEquals;
  final List<dynamic>? inValues;
  final List<PluginInputCondition>? and;

  PluginInputCondition({
    required this.field,
    this.equals,
    this.notEquals,
    this.inValues,
    this.and,
  });

  factory PluginInputCondition.fromJson(Map<String, dynamic> json) {
    return PluginInputCondition(
      field: json['field']?.toString() ?? '',
      equals: json['equals'],
      notEquals: json['notEquals'],
      inValues: ((json['in'] ?? json['inValues']) as List?)?.toList(),
      and: (json['and'] as List?)
          ?.map((e) => PluginInputCondition.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// 插件输入参数定义
class PluginInputDef {
  final String id;
  final String label;
  final String type; // file_picker, slider, select, number, text
  final bool required;
  final bool allowMultiple;
  final List<String> allowedExtensions;
  final dynamic defaultValue;
  final double? min;
  final double? max;
  final double? step;
  final List<PluginSelectOption> options;
  final PluginInputCondition? visibleIf;
  final List<String> platforms; // universal, windows, android

  PluginInputDef({
    required this.id,
    required this.label,
    required this.type,
    this.required = false,
    this.allowMultiple = false,
    this.allowedExtensions = const [],
    this.defaultValue,
    this.min,
    this.max,
    this.step,
    this.options = const [],
    this.visibleIf,
    this.platforms = const ['universal'],
  });

  bool isSupportedOnCurrentPlatform() {
    if (platforms.isEmpty || platforms.contains('universal')) return true;
    if (Platform.isWindows && platforms.contains('windows')) return true;
    if (Platform.isAndroid && platforms.contains('android')) return true;
    return false;
  }

  String get platformBadgeText {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    if (lower.contains('windows') && !lower.contains('android') && !lower.contains('universal')) {
      return '🪟 Windows 专享';
    }
    if (lower.contains('android') && !lower.contains('windows') && !lower.contains('universal')) {
      return '🤖 Android 专享';
    }
    return '🌐 全平台通用';
  }

  bool isWindowsOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('windows') && !lower.contains('universal');
  }

  bool isAndroidOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('android') && !lower.contains('universal');
  }

  factory PluginInputDef.fromJson(Map<String, dynamic> json) {
    var rawOptions = json['options'] as List?;
    var rawPlatforms = json['platforms'] as List?;
    return PluginInputDef(
      id: json['id'] ?? '',
      label: json['label'] ?? '',
      type: json['type'] ?? 'text',
      required: json['required'] ?? false,
      allowMultiple: json['allowMultiple'] ?? false,
      allowedExtensions: (json['allowedExtensions'] as List?)?.map((e) => e.toString()).toList() ?? [],
      defaultValue: json['defaultValue'],
      min: (json['min'] as num?)?.toDouble(),
      max: (json['max'] as num?)?.toDouble(),
      step: (json['step'] as num?)?.toDouble(),
      options: rawOptions != null
          ? rawOptions.map((e) => PluginSelectOption.fromJson(e)).toList()
          : [],
      visibleIf: json['visibleIf'] != null
          ? PluginInputCondition.fromJson(Map<String, dynamic>.from(json['visibleIf']))
          : null,
      platforms: rawPlatforms != null
          ? rawPlatforms.map((e) => e.toString().toLowerCase()).toList()
          : const ['universal'],
    );
  }
}

class PluginSelectOption {
  final String label;
  final String value;
  final List<String> platforms; // universal, windows, android

  PluginSelectOption({
    required this.label,
    required this.value,
    this.platforms = const ['universal'],
  });

  bool isSupportedOnCurrentPlatform() {
    if (platforms.isEmpty || platforms.contains('universal')) return true;
    if (Platform.isWindows && platforms.contains('windows')) return true;
    if (Platform.isAndroid && platforms.contains('android')) return true;
    return false;
  }

  String get platformBadgeText {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    if (lower.contains('windows') && !lower.contains('android') && !lower.contains('universal')) {
      return '🪟 Windows 专享';
    }
    if (lower.contains('android') && !lower.contains('windows') && !lower.contains('universal')) {
      return '🤖 Android 专享';
    }
    return '🌐 全平台通用';
  }

  bool isWindowsOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('windows') && !lower.contains('universal');
  }

  bool isAndroidOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('android') && !lower.contains('universal');
  }

  factory PluginSelectOption.fromJson(Map<String, dynamic> json) {
    var rawPlatforms = json['platforms'] as List?;
    return PluginSelectOption(
      label: json['label']?.toString() ?? '',
      value: json['value']?.toString() ?? '',
      platforms: rawPlatforms != null
          ? rawPlatforms.map((e) => e.toString().toLowerCase()).toList()
          : const ['universal'],
    );
  }
}

/// 插件处理流水线 / 动作定义
class PluginActionDef {
  final String handler;
  final Map<String, dynamic> params;

  PluginActionDef({required this.handler, required this.params});

  factory PluginActionDef.fromJson(Map<String, dynamic> json) {
    return PluginActionDef(
      handler: json['handler'] ?? '',
      params: Map<String, dynamic>.from(json['params'] ?? {}),
    );
  }
}

/// 外部独立程序/脚本运行配置 (Windows 开放扩展工坊专属)
class PluginNativeRunnerDef {
  final String entry; // 可执行文件相对路径 (如 "bin/tool.exe") 或系统命令 ("powershell.exe", "python.exe")
  final List<String> args; // 参数模板列表 (支持占位符如 {outputDir}, {input}, {url} 等)
  final String? workingDir;
  final String? downloadUrl; // 若本地 bin 不存在，从第三方/社区镜像一键拉取
  final Map<String, String> downloadUrls; // 多镜像源下载支持
  final String? sha256;
  final int? binSize;
  final bool showTerminal; // 是否在界面展示流式命令行终端黑框
  final String? shell; // "cmd", "powershell", "python" 或 null (直接执行 exe)
  final String? runMode; // "process" (后台静默+日志流捕获) 或 "external_window" (调起系统独立窗口)

  PluginNativeRunnerDef({
    required this.entry,
    this.args = const [],
    this.workingDir,
    this.downloadUrl,
    this.downloadUrls = const {},
    this.sha256,
    this.binSize,
    this.showTerminal = true,
    this.shell,
    this.runMode = 'process',
  });

  factory PluginNativeRunnerDef.fromJson(Map<String, dynamic> json) {
    return PluginNativeRunnerDef(
      entry: json['entry']?.toString() ?? '',
      args: (json['args'] as List?)?.map((e) => e.toString()).toList() ?? [],
      workingDir: json['workingDir']?.toString(),
      downloadUrl: json['downloadUrl']?.toString(),
      downloadUrls: (json['downloadUrls'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
      sha256: json['sha256']?.toString(),
      binSize: (json['binSize'] as num?)?.toInt(),
      showTerminal: json['showTerminal'] ?? true,
      shell: json['shell']?.toString(),
      runMode: json['runMode']?.toString() ?? 'process',
    );
  }

  Map<String, dynamic> toJson() => {
    'entry': entry,
    'args': args,
    if (workingDir != null) 'workingDir': workingDir,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (downloadUrls.isNotEmpty) 'downloadUrls': downloadUrls,
    if (sha256 != null) 'sha256': sha256,
    if (binSize != null) 'binSize': binSize,
    'showTerminal': showTerminal,
    if (shell != null) 'shell': shell,
    'runMode': runMode,
  };
}

/// 插件本地/远程实体
class PluginManifest {
  final String id;
  final String name;
  final String version;
  final String minAppVersion;
  final String category; // image, media, text, other, win_ext
  final String description;
  final String icon;
  final String author;
  final String engineType; // native_image, media_pipeline, webview, native_executable, script
  final String executionType; // 'internal' | 'native_executable' | 'script' | 'quickjs'
  final PluginNativeRunnerDef? nativeRunner;
  final String? downloadUrl;
  final Map<String, String> downloadUrls;
  final bool isOfficial;
  final int? size;
  final String? md5;
  final List<PluginInputDef> inputs;
  final PluginActionDef? action;
  final List<String> platforms; // universal, windows, android
  
  // 运行期状态
  bool isInstalled;
  bool isUpdateAvailable;
  String? localDir;

  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.minAppVersion = '1.0.0',
    required this.category,
    required this.description,
    required this.icon,
    required this.author,
    required this.engineType,
    this.executionType = 'internal',
    this.nativeRunner,
    this.downloadUrl,
    this.downloadUrls = const {},
    this.isOfficial = false,
    this.size,
    this.md5,
    this.inputs = const [],
    this.action,
    this.platforms = const ['universal'],
    this.isInstalled = false,
    this.isUpdateAvailable = false,
    this.localDir,
  });

  bool isSupportedOnCurrentPlatform() {
    if (platforms.isEmpty || platforms.contains('universal')) return true;
    if (Platform.isWindows && platforms.contains('windows')) return true;
    if (Platform.isAndroid && platforms.contains('android')) return true;
    return false;
  }

  /// 是否为 Windows 专属扩展工坊工具 (调度外部 exe 或外部脚本)
  bool get isWindowsExtension {
    return isWindowsOnly() && (
      executionType == 'native_executable' ||
      executionType == 'script' ||
      nativeRunner != null ||
      category == 'win_ext'
    );
  }

  /// 是否开启实时终端命令行回显控制台
  bool get hasTerminal {
    return nativeRunner?.showTerminal == true ||
        executionType == 'native_executable' ||
        executionType == 'script';
  }

  String get platformBadgeText {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    if (isWindowsExtension) {
      return '⚡ Win 开放扩展';
    }
    if (lower.contains('windows') && !lower.contains('android') && !lower.contains('universal')) {
      return '🪟 Windows 专享';
    }
    if (lower.contains('android') && !lower.contains('windows') && !lower.contains('universal')) {
      return '🤖 Android 专享';
    }
    return '🌐 全平台通用';
  }

  bool isWindowsOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('windows') && !lower.contains('universal');
  }

  bool isAndroidOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('android') && !lower.contains('universal');
  }

  factory PluginManifest.fromJson(Map<String, dynamic> json, {bool isRemote = false}) {
    var rawInputs = json['inputs'] as List?;
    var rawPlatforms = json['platforms'] as List?;
    return PluginManifest(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      version: json['version'] ?? '1.0.0',
      minAppVersion: json['minAppVersion']?.toString() ?? '1.0.0',
      category: json['category'] ?? 'other',
      description: json['description'] ?? '',
      icon: json['icon'] ?? 'extension',
      author: json['author'] ?? 'Unknown',
      engineType: json['engineType'] ?? 'custom',
      executionType: json['executionType']?.toString() ??
          (json['nativeRunner'] != null ? 'native_executable' : 'internal'),
      nativeRunner: json['nativeRunner'] != null
          ? PluginNativeRunnerDef.fromJson(Map<String, dynamic>.from(json['nativeRunner']))
          : null,
      downloadUrl: json['downloadUrl'],
      downloadUrls: (json['downloadUrls'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
      isOfficial: json['isOfficial'] ?? false,
      size: json['size'],
      md5: json['md5'],
      inputs: rawInputs != null
          ? rawInputs.map((e) => PluginInputDef.fromJson(e)).toList()
          : [],
      action: json['action'] != null ? PluginActionDef.fromJson(json['action']) : null,
      platforms: rawPlatforms != null
          ? rawPlatforms.map((e) => e.toString().toLowerCase()).toList()
          : const ['universal'],
      isInstalled: !isRemote,
    );
  }
}
