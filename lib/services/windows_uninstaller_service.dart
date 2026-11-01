import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Registry data only; querying Win32_Product can trigger MSI repairs.
class InstalledWindowsApp {
  const InstalledWindowsApp({
    required this.id,
    required this.name,
    required this.registryHive,
    required this.registryView,
    required this.registryKey,
    this.version = '',
    this.publisher = '',
    this.installLocation = '',
    this.uninstallString = '',
    this.installDate = '',
    this.estimatedBytes = 0,
    this.systemComponent = false,
    this.windowsInstaller = false,
    this.noRemove = false,
  });

  final String id;
  final String name;
  final String version;
  final String publisher;
  final String registryHive;
  final String registryView;
  final String registryKey;
  final String installLocation;
  final String uninstallString;
  final String installDate;
  final int estimatedBytes;
  final bool systemComponent;
  final bool windowsInstaller;
  final bool noRemove;

  bool get canUninstall =>
      !systemComponent &&
      !noRemove &&
      (uninstallString.trim().isNotEmpty ||
          (windowsInstaller && UninstallCommand.isProductCode(registryKey)));
  String get scopeLabel => registryHive == 'CurrentUser' ? '当前用户' : '所有用户';
  String get architecture => registryView == 'Registry64' ? '64 位' : '32 位';
  String get registryPath =>
      '${registryHive == 'CurrentUser' ? 'HKEY_CURRENT_USER' : 'HKEY_LOCAL_MACHINE'}\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$registryKey';
  String get formattedSize {
    if (estimatedBytes <= 0) return '未提供';
    if (estimatedBytes >= 1024 * 1024 * 1024) {
      return '${(estimatedBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(estimatedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory InstalledWindowsApp.fromJson(Map<String, dynamic> json) {
    String text(String key) => json[key]?.toString() ?? '';
    return InstalledWindowsApp(
      id: text('id'),
      name: text('name'),
      version: text('version'),
      publisher: text('publisher'),
      registryHive: text('registryHive'),
      registryView: text('registryView'),
      registryKey: text('registryKey'),
      installLocation: text('installLocation'),
      uninstallString: text('uninstallString'),
      installDate: text('installDate'),
      estimatedBytes: (num.tryParse(text('estimatedBytes')) ?? 0).toInt(),
      systemComponent: json['systemComponent'] == true,
      windowsInstaller: json['windowsInstaller'] == true,
      noRemove: json['noRemove'] == true,
    );
  }
}

class WindowsAppInventory {
  const WindowsAppInventory(this.apps, {this.warnings = const []});
  final List<InstalledWindowsApp> apps;
  final List<String> warnings;
}

class UninstallCommand {
  const UninstallCommand(this.executable, this.arguments);
  final String executable;

  /// Original argument string, kept intact for Windows command-line parsing.
  final String arguments;

  static bool isProductCode(String value) => RegExp(
        r'^\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}$',
        caseSensitive: false,
      ).hasMatch(value);

  static String _systemExecutable(String name) => p.windows.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows', 'System32', name);

  /// Find the MSI operation outside quoted property values. Preserve every
  /// character of the remaining Windows argument string.
  static String _msiUninstallArguments(String arguments) {
    var quoted = false;
    for (var index = 0; index < arguments.length; index++) {
      if (arguments[index] == '"') {
        var backslashes = 0;
        for (var previous = index - 1;
            previous >= 0 && arguments[previous] == r'\';
            previous--) {
          backslashes++;
        }
        if (backslashes.isEven) quoted = !quoted;
      }
      if (quoted ||
          (index > 0 && !RegExp(r'\s').hasMatch(arguments[index - 1]))) {
        continue;
      }
      final remaining = arguments.substring(index);
      final operation =
          RegExp(r'^/(i|package)(?=\s|\{|"|$)', caseSensitive: false)
              .firstMatch(remaining);
      if (operation != null) {
        return arguments.replaceRange(index, index + operation.end, '/X');
      }
    }
    return arguments;
  }

  factory UninstallCommand.fromApp(InstalledWindowsApp app) {
    if (!app.canUninstall) throw const FormatException('此条目不支持卸载。');
    final command = app.uninstallString.trim();
    if (command.isEmpty &&
        app.windowsInstaller &&
        isProductCode(app.registryKey)) {
      return UninstallCommand(
          _systemExecutable('msiexec.exe'), '/X ${app.registryKey}');
    }
    final quoted = RegExp(r'^"([^"\r\n]+\.exe)"\s*(.*)$', caseSensitive: false)
        .firstMatch(command);
    final plain =
        RegExp(r'^([^"\r\n]+?\.exe)(?:\s+(.*))?$', caseSensitive: false)
            .firstMatch(command);
    final msi = RegExp(r'^(msiexec)(?:\s+(.*))?$', caseSensitive: false)
        .firstMatch(command);
    final match = quoted ?? plain ?? msi;
    if (match == null) {
      throw const FormatException('卸载命令格式不明确，请在 Windows 设置中卸载此程序。');
    }
    var executable = match.group(1)!.trim();
    final environment = {
      for (final entry in Platform.environment.entries)
        entry.key.toLowerCase(): entry.value,
    };
    executable = executable.replaceAllMapped(
        RegExp(r'%([^%]+)%'),
        (match) =>
            environment[match.group(1)!.toLowerCase()] ?? match.group(0)!);
    var arguments = match.group(2)?.trim() ?? '';
    if (executable.toLowerCase() == 'msiexec') executable = 'msiexec.exe';
    final basename = p.windows.basename(executable).toLowerCase();
    // Registry arguments never pass through cmd.exe or Invoke-Expression.
    if (basename == 'msiexec.exe') {
      arguments = _msiUninstallArguments(arguments);
    }
    if (!p.windows.isAbsolute(executable) &&
        !const ['msiexec.exe', 'rundll32.exe'].contains(basename)) {
      throw const FormatException('卸载程序没有绝对路径，请在 Windows 设置中卸载。');
    }
    if (!p.windows.isAbsolute(executable)) {
      executable = _systemExecutable(basename);
    }
    return UninstallCommand(executable, arguments);
  }

  String get display =>
      '"$executable"${arguments.isEmpty ? '' : ' $arguments'}';
}

class WindowsUninstallResult {
  const WindowsUninstallResult(this.exitCode);
  final int exitCode;
  bool get succeeded => const [0, 1641, 3010].contains(exitCode);
  bool get restartRequired => const [1641, 3010].contains(exitCode);
  String get message => succeeded
      ? (restartRequired ? '卸载程序已完成，Windows 提示需要重启。' : '卸载程序已退出，请刷新并确认结果。')
      : '卸载程序退出码：$exitCode。可尝试以管理员身份卸载。';
}

class WindowsResidueCandidate {
  const WindowsResidueCandidate(
      {required this.path, required this.kind, required this.note});
  final String path;
  final String kind;
  final String note;
}

typedef WindowsProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class WindowsUninstallerService {
  WindowsUninstallerService(
      {WindowsProcessRunner? processRunner, bool? supported})
      : _runner = processRunner ?? _defaultRunner,
        isSupported = supported ?? Platform.isWindows;

  final WindowsProcessRunner _runner;
  final bool isSupported;
  static Future<ProcessResult> _defaultRunner(
          String executable, List<String> arguments) =>
      Process.run(executable, arguments,
          stdoutEncoding: utf8, stderrEncoding: utf8);

  Future<dynamic> _runJson(String script) async {
    if (!isSupported) throw UnsupportedError('软件卸载助手仅支持 Windows。');
    // -EncodedCommand requires UTF-16LE; data payloads are JSON/base64.
    final units = script.codeUnits;
    final encoded = base64Encode([
      for (final unit in units) ...[unit & 255, unit >> 8]
    ]);
    final windowsRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = await _runner(
      p.windows.join(windowsRoot, 'System32', 'WindowsPowerShell', 'v1.0',
          'powershell.exe'),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        encoded
      ],
    );
    if (result.exitCode != 0) {
      final error = result.stderr.toString().trim();
      throw ProcessException('powershell.exe', const [],
          error.isEmpty ? 'Windows 操作未完成。' : error, result.exitCode);
    }
    final output = result.stdout.toString().replaceFirst('\uFEFF', '').trim();
    if (output.isEmpty) throw const FormatException('Windows 没有返回有效结果。');
    return jsonDecode(output);
  }

  static const _jsonHeader = r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
''';

  static const inventoryScript = r'''
$items = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$views = @([Microsoft.Win32.RegistryView]::Registry32)
if ([Environment]::Is64BitOperatingSystem) {
  $views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
}
foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)) {
  foreach ($view in $views) {
    $base = $null
    $uninstall = $null
    try {
      $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
      $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $false)
      if ($null -eq $uninstall) { continue }
      foreach ($name in $uninstall.GetSubKeyNames()) {
        $key = $null
        try {
          $key = $uninstall.OpenSubKey($name, $false)
          if ($null -eq $key) { continue }
          $display = [string]$key.GetValue('DisplayName', '')
          if ([string]::IsNullOrWhiteSpace($display)) { continue }
          $size = 0L
          try { $size = [Math]::Max(0L, [long]$key.GetValue('EstimatedSize', 0)) * 1024L } catch {}
          $items.Add([PSCustomObject]@{
            id = "$hive|$view|$name"; name = $display
            version = [string]$key.GetValue('DisplayVersion', '')
            publisher = [string]$key.GetValue('Publisher', '')
            installLocation = [string]$key.GetValue('InstallLocation', '')
            uninstallString = [string]$key.GetValue('UninstallString', '')
            installDate = [string]$key.GetValue('InstallDate', '')
            estimatedBytes = $size; registryHive = [string]$hive
            registryView = [string]$view; registryKey = $name
            systemComponent = ($key.GetValue('SystemComponent', 0) -eq 1)
            windowsInstaller = ($key.GetValue('WindowsInstaller', 0) -eq 1)
            noRemove = ($key.GetValue('NoRemove', 0) -eq 1)
          })
        } catch { $warnings.Add("无法读取条目 $hive/$view/$name") }
        finally { if ($null -ne $key) { $key.Dispose() } }
      }
    } catch { $warnings.Add("无法读取注册表视图 $hive/$view") }
    finally {
      if ($null -ne $uninstall) { $uninstall.Dispose() }
      if ($null -ne $base) { $base.Dispose() }
    }
  }
}
[PSCustomObject]@{apps = @($items.ToArray()); warnings = @($warnings.ToArray())} | ConvertTo-Json -Depth 5 -Compress
''';

  Future<WindowsAppInventory> loadApps() async {
    final raw = await _runJson('$_jsonHeader\n$inventoryScript');
    final data = Map<String, dynamic>.from(raw as Map);
    final apps = <InstalledWindowsApp>[];
    final seen = <String>{};
    for (final item in (data['apps'] as List? ?? const [])) {
      final app =
          InstalledWindowsApp.fromJson(Map<String, dynamic>.from(item as Map));
      if (app.name.trim().isEmpty) continue;
      // Only exact HKCU shared-key duplicates may collapse. HKLM registrations
      // remain separate across the redirected views even with identical names.
      final identity = jsonEncode([
        app.registryKey,
        app.uninstallString,
        app.name,
        app.version,
        app.publisher,
        app.installLocation,
        app.installDate,
        app.estimatedBytes,
        app.systemComponent,
        app.windowsInstaller,
        app.noRemove,
      ]);
      if (app.registryHive != 'CurrentUser' || seen.add(identity)) {
        apps.add(app);
      }
    }
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return WindowsAppInventory(apps,
        warnings: (data['warnings'] as List? ?? const [])
            .map((e) => e.toString())
            .toList());
  }

  Future<WindowsUninstallResult> uninstall(InstalledWindowsApp app,
      {bool elevate = false}) async {
    final command = UninstallCommand.fromApp(app);
    final payload = base64Encode(utf8.encode(jsonEncode({
      'executable': command.executable,
      'arguments': command.arguments,
      'elevate': elevate,
    })));
    final result = await _runJson('''$_jsonHeader
\$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json
\$start = New-Object System.Diagnostics.ProcessStartInfo
\$start.FileName = [Environment]::ExpandEnvironmentVariables([string]\$request.executable)
\$start.Arguments = [string]\$request.arguments
\$start.UseShellExecute = \$true
if (\$request.elevate) { \$start.Verb = 'runas' }
\$process = [Diagnostics.Process]::Start(\$start)
if (\$null -eq \$process) { throw '无法启动卸载程序。' }
\$process.WaitForExit()
[PSCustomObject]@{exitCode = \$process.ExitCode} | ConvertTo-Json -Compress
''');
    return WindowsUninstallResult((result['exitCode'] as num).toInt());
  }

  /// Checks exact registration and install folder only; never deletes anything.
  Future<List<WindowsResidueCandidate>> scanResidue(
      InstalledWindowsApp app) async {
    final payload = base64Encode(utf8.encode(jsonEncode({
      'hive': app.registryHive,
      'view': app.registryView,
      'key': app.registryKey,
      'location': app.installLocation,
    })));
    final raw = await _runJson('''$_jsonHeader
\$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json
\$items = New-Object System.Collections.Generic.List[object]
\$hive = [Microsoft.Win32.RegistryHive]::LocalMachine
if (\$request.hive -eq 'CurrentUser') { \$hive = [Microsoft.Win32.RegistryHive]::CurrentUser }
\$view = [Microsoft.Win32.RegistryView]::Registry32
if (\$request.view -eq 'Registry64') { \$view = [Microsoft.Win32.RegistryView]::Registry64 }
\$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(\$hive, \$view)
\$key = \$null
try {
  \$path = 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\' + [string]\$request.key
  \$key = \$base.OpenSubKey(\$path, \$false)
  if (\$null -ne \$key) {
    \$items.Add([PSCustomObject]@{path = \$base.Name + '\\' + \$path; kind = '注册表条目'; note = '原卸载注册项仍存在；程序可能尚未完成卸载。'})
  }
} finally { if (\$null -ne \$key) { \$key.Dispose() }; \$base.Dispose() }
\$location = [Environment]::ExpandEnvironmentVariables([string]\$request.location)
if (-not [string]::IsNullOrWhiteSpace(\$location) -and [IO.Path]::IsPathRooted(\$location)) {
  try {
    \$full = [IO.Path]::GetFullPath(\$location).TrimEnd('\\')
    \$protected = @([IO.Path]::GetPathRoot(\$full), \$env:SystemRoot, \$env:ProgramFiles, \${env:ProgramFiles(x86)}, \$env:ProgramData, \$env:USERPROFILE, \$env:LOCALAPPDATA, \$env:APPDATA, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))
    \$blocked = \$false
    foreach (\$entry in \$protected) {
      if (-not [string]::IsNullOrWhiteSpace(\$entry)) {
        \$normal = [IO.Path]::GetFullPath(\$entry).TrimEnd('\\')
        if (\$full.Equals(\$normal, [StringComparison]::OrdinalIgnoreCase)) { \$blocked = \$true }
      }
    }
    if (\$full.StartsWith(\$env:SystemRoot.TrimEnd('\\') + '\\', [StringComparison]::OrdinalIgnoreCase)) { \$blocked = \$true }
    if (-not \$blocked -and (Test-Path -LiteralPath \$full -PathType Container)) {
      \$folder = Get-Item -LiteralPath \$full -Force
      if ((\$folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        \$items.Add([PSCustomObject]@{path = \$full; kind = '原安装目录'; note = '仅依据 InstallLocation；可能包含共享文件或个人数据，需手动核对。'})
      }
    }
  } catch {}
}
ConvertTo-Json -InputObject @(\$items.ToArray()) -Depth 4 -Compress
''');
    return (raw as List)
        .map((item) => WindowsResidueCandidate(
              path: item['path'].toString(),
              kind: item['kind'].toString(),
              note: item['note'].toString(),
            ))
        .toList();
  }
}
