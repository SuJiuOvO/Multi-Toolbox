import 'dart:io';

/// 插件输入显示条件定义 (用于模式/选项切换时的联动隐藏显示)
class PluginInputCondition {
  final String field;
  final dynamic equals;
  final dynamic notEquals;
  final List<dynamic>? inValues;
  final List<PluginInputCondition>? and;
  final List<PluginInputCondition>? or;

  PluginInputCondition({
    required this.field,
    this.equals,
    this.notEquals,
    this.inValues,
    this.and,
    this.or,
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
      or: (json['or'] as List?)
          ?.map((e) => PluginInputCondition.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// 插件输入参数定义
class PluginInputDef {
  final String id;
  final String label;
  final String description;
  final String type; // file_picker, slider, select, number, text, switch
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
    this.description = '',
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
    return lower.contains('windows') && !lower.contains('android') && !lower.contains('universal');
  }

  bool isAndroidOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('android') && !lower.contains('windows') && !lower.contains('universal');
  }

  factory PluginInputDef.fromJson(Map<String, dynamic> json) {
    var rawOptions = json['options'] as List?;
    var rawPlatforms = json['platforms'] as List?;
    return PluginInputDef(
      id: json['id'] ?? '',
      label: json['label'] ?? '',
      description: json['description']?.toString() ?? '',
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
    return lower.contains('windows') && !lower.contains('android') && !lower.contains('universal');
  }

  bool isAndroidOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('android') && !lower.contains('windows') && !lower.contains('universal');
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

/// WebAssembly (WASM) 微内核沙箱运行配置 (跨平台跨架构统一执行 C/C++/Rust 字节码)
class PluginWasmRunnerDef {
  final String entry; // .wasm 模块文件相对路径 (如 "bin/tool.wasm" 或 "ncmdump.wasm")
  final String executionMode; // "wasi_cli", "memory_stream", "call_func"
  final List<String> args; // CLI 参数模板列表 (支持占位符如 {input}, {outputDir}, {input_base} 等)
  final bool batchMode; // 当多选输入文件时，是否自动逐个循环调度
  final String? functionName; // 待调用的导出函数名称 (call_func / memory_stream 模式)
  final Map<String, String> env; // 额外注入沙箱的环境变量
  final bool showTerminal; // 是否在界面展示终端运行日志黑框

  PluginWasmRunnerDef({
    required this.entry,
    this.executionMode = 'wasi_cli',
    this.args = const [],
    this.batchMode = true,
    this.functionName,
    this.env = const {},
    this.showTerminal = true,
  });

  factory PluginWasmRunnerDef.fromJson(Map<String, dynamic> json) {
    return PluginWasmRunnerDef(
      entry: json['entry']?.toString() ?? json['wasmPath']?.toString() ?? '',
      executionMode: json['executionMode']?.toString() ?? 'wasi_cli',
      args: (json['args'] as List?)?.map((e) => e.toString()).toList() ??
          (json['cliArgs'] != null ? [json['cliArgs'].toString()] : const []),
      batchMode: json['batchMode'] != false,
      functionName: json['functionName']?.toString(),
      env: (json['env'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? const {},
      showTerminal: json['showTerminal'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'entry': entry,
    'executionMode': executionMode,
    if (args.isNotEmpty) 'args': args,
    'batchMode': batchMode,
    if (functionName != null) 'functionName': functionName,
    if (env.isNotEmpty) 'env': env,
    'showTerminal': showTerminal,
  };
}

/// 功能模块图标定义 (支持图片限制尺寸与大小、代码渲染矢量SVG，以及系统默认图标降级)
class PluginIconDef {
  /// 默认最大支持图片文件大小：512 KB
  static const int defaultMaxSizeBytes = 512 * 1024;

  /// 默认最大支持像素宽高：512 x 512
  static const int defaultMaxPixels = 512;

  final String type; // 'image', 'code', 'material', 'default'
  final String? data; // base64 / 文件路径 / 网络URL / SVG矢量代码 / Material图标名
  final int maxSizeBytes;
  final int maxPixels;

  const PluginIconDef({
    required this.type,
    this.data,
    this.maxSizeBytes = defaultMaxSizeBytes,
    this.maxPixels = defaultMaxPixels,
  });

  /// 是否为图片模式 (Base64 / 本地文件 / 网络URL)
  bool get isImage => type == 'image';

  /// 是否为代码渲染模式 (SVG 矢量代码)
  bool get isCode => type == 'code';

  /// 是否为系统/Material 图标关键词
  bool get isMaterial => type == 'material';

  /// 是否未提供任何图标或强制默认
  bool get isDefault => type == 'default' || data == null || data!.trim().isEmpty;

  factory PluginIconDef.fromRaw(dynamic raw, {String fallbackIcon = 'extension'}) {
    if (raw == null) {
      return PluginIconDef(type: 'material', data: fallbackIcon);
    }
    if (raw is String) {
      final str = raw.trim();
      if (str.isEmpty) {
        return PluginIconDef(type: 'material', data: fallbackIcon);
      }
      // SVG 代码特征
      if (str.startsWith('<svg') || str.contains('xmlns="http://www.w3.org/2000/svg"')) {
        return PluginIconDef(type: 'code', data: str);
      }
      // 图片特征
      if (str.startsWith('data:image/') ||
          str.startsWith('http://') ||
          str.startsWith('https://') ||
          str.toLowerCase().endsWith('.png') ||
          str.toLowerCase().endsWith('.jpg') ||
          str.toLowerCase().endsWith('.jpeg') ||
          str.toLowerCase().endsWith('.webp') ||
          str.toLowerCase().endsWith('.gif') ||
          str.toLowerCase().endsWith('.bmp')) {
        return PluginIconDef(type: 'image', data: str);
      }
      // 默认为 Material 图标关键词
      return PluginIconDef(type: 'material', data: str);
    }
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final rawType = map['type']?.toString().toLowerCase().trim() ?? '';
      final data = map['data']?.toString() ??
          map['code']?.toString() ??
          map['content']?.toString() ??
          map['url']?.toString() ??
          map['path']?.toString() ??
          map['value']?.toString();
      final maxSizeBytes = (map['maxSizeBytes'] as num?)?.toInt() ??
          (map['maxSize'] as num?)?.toInt() ??
          defaultMaxSizeBytes;
      final maxPixels = (map['maxPixels'] as num?)?.toInt() ??
          (map['maxPixel'] as num?)?.toInt() ??
          defaultMaxPixels;

      final type = switch (rawType) {
        'image' || 'img' || 'bitmap' || 'file' || 'url' => 'image',
        'code' || 'svg' || 'xml' => 'code',
        'material' || 'icon' => 'material',
        'default' => 'default',
        _ => (data != null && (data.startsWith('<svg') || data.contains('<svg')))
            ? 'code'
            : (data != null && (data.startsWith('data:image/') || data.startsWith('http') || data.endsWith('.png')))
                ? 'image'
                : 'material',
      };

      return PluginIconDef(
        type: type,
        data: data ?? fallbackIcon,
        maxSizeBytes: maxSizeBytes,
        maxPixels: maxPixels,
      );
    }
    return PluginIconDef(type: 'material', data: fallbackIcon);
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (data != null) 'data': data,
    'maxSizeBytes': maxSizeBytes,
    'maxPixels': maxPixels,
  };
}

/// 插件结果输出项声明定义 (Manifest v2.4 规范)
class PluginOutputDef {
  final String id;
  final String label;
  final String type; // copyable_text, markdown, json_tree, key_value_table
  final String? description;

  PluginOutputDef({
    required this.id,
    required this.label,
    this.type = 'copyable_text',
    this.description,
  });

  factory PluginOutputDef.fromJson(Map<String, dynamic> json) {
    return PluginOutputDef(
      id: json['id']?.toString() ?? 'output',
      label: json['label']?.toString() ?? '执行产出',
      type: json['type']?.toString() ?? 'copyable_text',
      description: json['description']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'type': type,
    if (description != null) 'description': description,
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
  final PluginIconDef? iconDef;
  final String author;
  final String engineType; // native_image, media_pipeline, webview, native_executable, script
  final String executionType; // 'internal' | 'native_executable' | 'script' | 'quickjs' | 'wasm'
  final PluginNativeRunnerDef? nativeRunner;
  final PluginWasmRunnerDef? wasmRunner;
  final String? downloadUrl;
  final Map<String, String> downloadUrls;
  final bool isOfficial;
  final int? size;
  final String? md5;
  final List<PluginInputDef> inputs;
  final List<PluginOutputDef> outputs;
  final List<String> permissions; // e.g. 'network', 'fs_unrestricted'
  final PluginActionDef? action;
  final List<String> platforms; // universal, windows, android
  
  // 运行期状态
  bool isInstalled;
  bool isUpdateAvailable;
  String? localDir;
  bool isDevLink;

  PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.minAppVersion = '1.0.0',
    required this.category,
    required this.description,
    required this.icon,
    this.iconDef,
    required this.author,
    required this.engineType,
    this.executionType = 'internal',
    this.nativeRunner,
    this.wasmRunner,
    this.downloadUrl,
    this.downloadUrls = const {},
    this.isOfficial = false,
    this.size,
    this.md5,
    this.inputs = const [],
    this.outputs = const [],
    this.permissions = const [],
    this.action,
    this.platforms = const ['universal'],
    this.isInstalled = false,
    this.isUpdateAvailable = false,
    this.localDir,
    this.isDevLink = false,
  });

  PluginIconDef get effectiveIconDef => iconDef ?? PluginIconDef.fromRaw(icon);

  static const List<String> defaultPluginIds = [
    'image-compress',
    'image-resize',
    'id-photo-bg',
    'video-audio-toolbox',
    'qr-toolbox',
    'downloader-toolbox',
    'gif-toolbox',
    'livephoto-toolbox',
    'pdf-toolbox',
    'doc-converter',
    'windows-media-downloader',
    'universal-data-codec',
    'universal-archive-extractor',
    'universal-wasm-runner',
    'gemini-banana-watermark',
  ];

  /// 是否为客户端核心内置功能
  bool get isBuiltIn => defaultPluginIds.contains(id);

  bool isSupportedOnCurrentPlatform() {
    if (platforms.isEmpty || platforms.contains('universal')) return true;
    if (Platform.isWindows && platforms.contains('windows')) return true;
    if (Platform.isAndroid && platforms.contains('android')) return true;
    return false;
  }

  /// 是否为 Windows 专属扩展工坊工具 (调度外部 exe 或外部脚本)
  bool get isWindowsExtension {
    return isWindowsOnly() && !isDualAdaptivePlugin && (
      executionType == 'native_executable' ||
      (executionType == 'script' && nativeRunner != null) ||
      nativeRunner != null ||
      category == 'win_ext'
    );
  }

  /// 是否为 QuickJS 动态脚本插件 (沙箱执行，跨 Android/Windows 全平台热加载)
  bool get isQuickJsPlugin {
    return executionType == 'quickjs' ||
        (executionType == 'script' && nativeRunner == null) ||
        engineType == 'quickjs';
  }

  /// 是否为 WebAssembly (Wasm) 模块插件 (跨平台沙箱直接执行 C/C++/Rust 字节码)
  bool get isWasmPlugin {
    return wasmRunner != null ||
        executionType == 'wasm' ||
        engineType == 'wasm' ||
        action?.handler == 'wasm_runner' ||
        action?.handler == 'wasm_universal';
  }

  /// 是否开启实时终端命令行回显控制台
  bool get hasTerminal {
    return isQuickJsPlugin ||
        isWasmPlugin ||
        nativeRunner?.showTerminal == true ||
        executionType == 'native_executable' ||
        executionType == 'script';
  }

  /// 是否为双端自适应合一插件 (同时配置了 Windows 原生 nativeRunner 与跨平台 wasmRunner)
  bool get isDualAdaptivePlugin => nativeRunner != null && isWasmPlugin;

  String get platformBadgeText {
    if (isDevLink) {
      return '🛠️ 本地调试';
    }
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    if (isDualAdaptivePlugin) {
      return '🚀 双端自适应';
    }
    if (isWindowsExtension) {
      return '⚡ Win 开放扩展';
    }
    if (isQuickJsPlugin) {
      return '⚡ JS 动态插件';
    }
    if (isWasmPlugin) {
      return '🦀 Wasm 算力沙箱';
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
    return lower.contains('windows') && !lower.contains('android') && !lower.contains('universal');
  }

  bool isAndroidOnly() {
    final lower = platforms.map((e) => e.toLowerCase()).toList();
    return lower.contains('android') && !lower.contains('windows') && !lower.contains('universal');
  }

  /// 检查插件是否声明了某项受控权限
  bool hasPermission(String perm) => permissions.contains(perm.toLowerCase().trim());

  /// 是否具备联网请求权限
  bool get hasNetworkPermission => hasPermission('network');

  /// 是否声明了无限制文件系统访问权限
  bool get hasUnrestrictedFsPermission => hasPermission('fs_unrestricted') || hasPermission('fs:unrestricted');

  factory PluginManifest.fromJson(Map<String, dynamic> json, {bool isRemote = false}) {
    var rawInputs = json['inputs'] as List?;
    var rawOutputs = json['outputs'] as List?;
    var rawPlatforms = json['platforms'] as List?;
    var rawPerms = json['permissions'] as List?;
    final rawIcon = json['icon'] ?? json['iconDef'];
    final iconDef = PluginIconDef.fromRaw(rawIcon);
    final iconString = rawIcon is String ? rawIcon : (iconDef.data ?? 'extension');
    return PluginManifest(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      version: json['version'] ?? '1.0.0',
      minAppVersion: json['minAppVersion']?.toString() ?? '1.0.0',
      category: json['category'] ?? 'other',
      description: json['description'] ?? '',
      icon: iconString,
      iconDef: iconDef,
      author: json['author'] ?? 'Unknown',
      engineType: json['engineType'] ?? 'custom',
      executionType: json['executionType']?.toString() ??
          (json['nativeRunner'] != null ? 'native_executable' : 'internal'),
      nativeRunner: json['nativeRunner'] != null
          ? PluginNativeRunnerDef.fromJson(Map<String, dynamic>.from(json['nativeRunner']))
          : null,
      wasmRunner: json['wasmRunner'] != null
          ? PluginWasmRunnerDef.fromJson(Map<String, dynamic>.from(json['wasmRunner']))
          : null,
      downloadUrl: json['downloadUrl'],
      downloadUrls: (json['downloadUrls'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {},
      isOfficial: json['isOfficial'] ?? false,
      size: json['size'],
      md5: json['md5'],
      inputs: rawInputs != null
          ? rawInputs.map((e) => PluginInputDef.fromJson(e)).toList()
          : [],
      outputs: rawOutputs != null
          ? rawOutputs.map((e) => PluginOutputDef.fromJson(Map<String, dynamic>.from(e))).toList()
          : const [],
      permissions: rawPerms != null
          ? rawPerms.map((e) => e.toString().toLowerCase().trim()).toList()
          : const [],
      action: json['action'] != null ? PluginActionDef.fromJson(json['action']) : null,
      platforms: rawPlatforms != null
          ? rawPlatforms.map((e) => e.toString().toLowerCase()).toList()
          : const ['universal'],
      isInstalled: !isRemote,
    );
  }
}
