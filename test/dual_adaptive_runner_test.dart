import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/pages/dynamic_tool_runner_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dual-Adaptive PluginManifest & Badge Tests', () {
    test('Plugin with both nativeRunner and wasmRunner is recognized as dual-adaptive', () {
      final dualManifest = PluginManifest(
        id: 'ncm-decryptor',
        name: '网易云 NCM 解密',
        version: '1.0.0',
        category: 'audio',
        description: 'Windows 极速原生 EXE + Android WASM 沙箱双端合一解密器',
        icon: 'lock_open',
        author: 'Toolbox Team',
        engineType: 'native_executable',
        platforms: ['windows', 'android'],
        nativeRunner: PluginNativeRunnerDef(
          entry: 'bin/ncmdump.exe',
          args: ['-i', '{input}', '-o', '{output}'],
        ),
        wasmRunner: PluginWasmRunnerDef(
          entry: 'bin/ncmdump.wasm',
          executionMode: 'cli',
          args: ['-i', '{input}', '-o', '{output}'],
        ),
      );

      expect(dualManifest.isDualAdaptivePlugin, isTrue);
      expect(dualManifest.isWindowsExtension, isFalse); // Not windows-only
      expect(dualManifest.isWasmPlugin, isTrue);
      expect(dualManifest.platformBadgeText, '🚀 双端自适应');
    });

    test('Single-engine plugins are not recognized as dual-adaptive', () {
      final winOnly = PluginManifest(
        id: 'win-only-tool',
        name: 'Win 专用工具',
        version: '1.0.0',
        category: 'win_ext',
        description: '仅 Windows 原生',
        icon: 'desktop_windows',
        author: 'Tester',
        engineType: 'native_executable',
        platforms: ['windows'],
        nativeRunner: PluginNativeRunnerDef(entry: 'bin/tool.exe'),
      );
      expect(winOnly.isDualAdaptivePlugin, isFalse);
      expect(winOnly.isWindowsExtension, isTrue);
      expect(winOnly.platformBadgeText, '⚡ Win 开放扩展');

      final wasmOnly = PluginManifest(
        id: 'wasm-only-tool',
        name: 'Wasm 专用工具',
        version: '1.0.0',
        category: 'tools',
        description: '仅 WASM 沙箱',
        icon: 'memory',
        author: 'Tester',
        engineType: 'wasm',
        platforms: ['universal'],
        wasmRunner: PluginWasmRunnerDef(
          entry: 'bin/tool.wasm',
          executionMode: 'cli',
        ),
      );
      expect(wasmOnly.isDualAdaptivePlugin, isFalse);
      expect(wasmOnly.isWasmPlugin, isTrue);
      expect(wasmOnly.platformBadgeText, '🦀 Wasm 算力沙箱');
    });
  });

  group('DynamicToolRunnerPage Adaptive Route Engine Resolution Tests', () {
    final dualPlugin = PluginManifest(
      id: 'dual-tool',
      name: '双端合一工具',
      version: '1.0.0',
      category: 'tools',
      description: '双端自适应',
      icon: 'sync',
      author: 'Tester',
      engineType: 'native_executable',
      platforms: ['windows', 'android'],
      nativeRunner: PluginNativeRunnerDef(entry: 'bin/tool.exe'),
      wasmRunner: PluginWasmRunnerDef(entry: 'bin/tool.wasm', executionMode: 'cli'),
    );

    final winOnlyPlugin = PluginManifest(
      id: 'win-tool',
      name: 'Windows 工具',
      version: '1.0.0',
      category: 'win_ext',
      description: 'Windows 专属',
      icon: 'desktop_windows',
      author: 'Tester',
      engineType: 'native_executable',
      platforms: ['windows'],
      nativeRunner: PluginNativeRunnerDef(entry: 'bin/tool.exe'),
    );

    final quickJsPlugin = PluginManifest(
      id: 'js-tool',
      name: 'JS 脚本工具',
      version: '1.0.0',
      category: 'script',
      description: 'QuickJS 脚本',
      icon: 'code',
      author: 'Tester',
      engineType: 'quickjs',
    );

    final wasmOnlyPlugin = PluginManifest(
      id: 'wasm-tool',
      name: 'WASM 工具',
      version: '1.0.0',
      category: 'tools',
      description: 'WASM 字节码',
      icon: 'memory',
      author: 'Tester',
      engineType: 'wasm',
      wasmRunner: PluginWasmRunnerDef(entry: 'bin/tool.wasm', executionMode: 'cli'),
    );

    final internalPlugin = PluginManifest(
      id: 'internal-tool',
      name: '内置原生图片工具',
      version: '1.0.0',
      category: 'image',
      description: 'Flutter 原生图形处理',
      icon: 'image',
      author: 'Tester',
      engineType: 'native_image',
      action: PluginActionDef(handler: 'image_compress', params: {}),
    );

    test('Dual-adaptive plugin routes to native EXE on Windows and WASM on Android', () {
      // 1. On Windows: Must dispatch to WindowsExtensionRunnerService (Native EXE)
      final winEngine = DynamicToolRunnerPage.resolveExecutionEngine(
        plugin: dualPlugin,
        isWindows: true,
      );
      expect(winEngine, PluginExecutionEngine.windowsNative);

      // 2. On Android: Must automatically fall through to WasmUniversalService (WASM)
      final androidEngine = DynamicToolRunnerPage.resolveExecutionEngine(
        plugin: dualPlugin,
        isWindows: false,
      );
      expect(androidEngine, PluginExecutionEngine.wasmUniversal);
    });

    test('Windows-only plugin dispatches to windowsNative regardless of OS (handled by service guard)', () {
      final winEngine = DynamicToolRunnerPage.resolveExecutionEngine(
        plugin: winOnlyPlugin,
        isWindows: true,
      );
      expect(winEngine, PluginExecutionEngine.windowsNative);

      final androidEngine = DynamicToolRunnerPage.resolveExecutionEngine(
        plugin: winOnlyPlugin,
        isWindows: false,
      );
      // Non-windows with only nativeRunner falls through to windowsNative, which returns graceful OS error
      expect(androidEngine, PluginExecutionEngine.windowsNative);
    });

    test('QuickJS plugin always routes to quickJs on both Windows and Android', () {
      expect(
        DynamicToolRunnerPage.resolveExecutionEngine(plugin: quickJsPlugin, isWindows: true),
        PluginExecutionEngine.quickJs,
      );
      expect(
        DynamicToolRunnerPage.resolveExecutionEngine(plugin: quickJsPlugin, isWindows: false),
        PluginExecutionEngine.quickJs,
      );
    });

    test('WASM-only plugin routes to wasmUniversal on both Windows and Android', () {
      expect(
        DynamicToolRunnerPage.resolveExecutionEngine(plugin: wasmOnlyPlugin, isWindows: true),
        PluginExecutionEngine.wasmUniversal,
      );
      expect(
        DynamicToolRunnerPage.resolveExecutionEngine(plugin: wasmOnlyPlugin, isWindows: false),
        PluginExecutionEngine.wasmUniversal,
      );
    });

    test('Internal Flutter tool routes to internalHandler on both Windows and Android', () {
      expect(
        DynamicToolRunnerPage.resolveExecutionEngine(plugin: internalPlugin, isWindows: true),
        PluginExecutionEngine.internalHandler,
      );
      expect(
        DynamicToolRunnerPage.resolveExecutionEngine(plugin: internalPlugin, isWindows: false),
        PluginExecutionEngine.internalHandler,
      );
    });
  });
}
