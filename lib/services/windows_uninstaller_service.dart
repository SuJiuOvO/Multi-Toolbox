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
    this.displayIcon = '',
    this.iconPath = '',
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
  final String displayIcon;
  final String iconPath;
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
      displayIcon: text('displayIcon'),
      iconPath: text('iconPath'),
      estimatedBytes: (num.tryParse(text('estimatedBytes')) ?? 0).toInt(),
      systemComponent: json['systemComponent'] == true,
      windowsInstaller: json['windowsInstaller'] == true,
      noRemove: json['noRemove'] == true,
    );
  }

  InstalledWindowsApp copyWith({String? iconPath}) => InstalledWindowsApp(
        id: id,
        name: name,
        version: version,
        publisher: publisher,
        registryHive: registryHive,
        registryView: registryView,
        registryKey: registryKey,
        installLocation: installLocation,
        uninstallString: uninstallString,
        installDate: installDate,
        displayIcon: displayIcon,
        iconPath: iconPath ?? this.iconPath,
        estimatedBytes: estimatedBytes,
        systemComponent: systemComponent,
        windowsInstaller: windowsInstaller,
        noRemove: noRemove,
      );
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
  const WindowsResidueCandidate({
    required this.path,
    required this.kind,
    required this.note,
    this.targetType = '',
    this.registryHive = '',
    this.registryView = '',
    this.registryPath = '',
    this.canDelete = false,
  });
  final String path;
  final String kind;
  final String note;
  final String targetType;
  final String registryHive;
  final String registryView;
  final String registryPath;
  final bool canDelete;
}

class WindowsResidueActionResult {
  const WindowsResidueActionResult({
    this.deletedPaths = const [],
    this.errors = const [],
  });
  final List<String> deletedPaths;
  final List<String> errors;
  bool get succeeded => errors.isEmpty;
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
          $displayIcon = [string]$key.GetValue('DisplayIcon', '')
          $entryId = "$hive|$view|$name"
          $items.Add([PSCustomObject]@{
            id = $entryId; name = $display
            version = [string]$key.GetValue('DisplayVersion', '')
            publisher = [string]$key.GetValue('Publisher', '')
            installLocation = [string]$key.GetValue('InstallLocation', '')
            uninstallString = [string]$key.GetValue('UninstallString', '')
            installDate = [string]$key.GetValue('InstallDate', '')
            displayIcon = $displayIcon
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

  Future<Map<String, String>> loadIconPaths(
      List<InstalledWindowsApp> apps) async {
    final entries = [
      for (final item in apps)
        if (item.displayIcon.trim().isNotEmpty)
          {'id': item.id, 'source': item.displayIcon},
    ];
    if (entries.isEmpty) return const {};
    final result = <String, String>{};
    // Windows limits a process command line to roughly 32K characters.
    // Keep each encoded PowerShell payload small enough for long display paths.
    const batchSize = 12;
    for (var offset = 0; offset < entries.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, entries.length);
      result.addAll(await _loadIconBatch(entries.sublist(offset, end)));
    }
    return result;
  }

  Future<Map<String, String>> _loadIconBatch(
      List<Map<String, String>> entries) async {
    final payload = base64Encode(utf8.encode(jsonEncode({'entries': entries})));
    final raw = await _runJson('''$_jsonHeader
try { Add-Type -AssemblyName System.Drawing } catch {}
\$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json
\$cache = Join-Path ([IO.Path]::GetTempPath()) 'MultiToolboxAppIcons'
[IO.Directory]::CreateDirectory(\$cache) | Out-Null
\$results = New-Object System.Collections.Generic.List[object]
foreach (\$entry in @(\$request.entries)) {
  try {
    \$source = [string]\$entry.source
    \$source = \$source.Trim()
    if (\$source.StartsWith('"')) {
      \$closing = \$source.IndexOf('"', 1)
      if (\$closing -gt 1) { \$source = \$source.Substring(1, \$closing - 1) }
    } else {
      \$source = (\$source -split ',')[0].Trim().Trim('"')
    }
    \$source = [Environment]::ExpandEnvironmentVariables(\$source)
    if (-not [IO.Path]::IsPathRooted(\$source) -or -not [IO.File]::Exists(\$source)) { continue }
    \$md5 = [Security.Cryptography.MD5]::Create()
    try {
      \$hash = [BitConverter]::ToString(\$md5.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]\$entry.id))).Replace('-', '').ToLowerInvariant()
    } finally { \$md5.Dispose() }
    \$target = Join-Path \$cache (\$hash + '.png')
    if (-not [IO.File]::Exists(\$target)) {
      \$icon = \$null
      \$bitmap = \$null
      try {
        if (\$source.EndsWith('.ico', [StringComparison]::OrdinalIgnoreCase)) {
          \$icon = New-Object System.Drawing.Icon(\$source)
        } else {
          \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon(\$source)
        }
        if (\$null -eq \$icon) { continue }
        \$bitmap = \$icon.ToBitmap()
        \$bitmap.Save(\$target, [System.Drawing.Imaging.ImageFormat]::Png)
      } finally {
        if (\$null -ne \$bitmap) { \$bitmap.Dispose() }
        if (\$null -ne \$icon) { \$icon.Dispose() }
      }
    }
    \$results.Add([PSCustomObject]@{id=[string]\$entry.id; path=\$target})
  } catch {}
}
ConvertTo-Json -InputObject @(\$results.ToArray()) -Depth 4 -Compress
''');
    final result = <String, String>{};
    for (final item in (raw as List? ?? const [])) {
      if (item is! Map) continue;
      final id = item['id']?.toString() ?? '';
      final path = item['path']?.toString() ?? '';
      if (id.isNotEmpty && path.isNotEmpty) result[id] = path;
    }
    return result;
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

  /// Finds exact, conservatively derived leftovers without deleting anything.
  Future<List<WindowsResidueCandidate>> scanResidue(
      InstalledWindowsApp app) async {
    final payload = base64Encode(utf8.encode(jsonEncode({
      'name': app.name,
      'publisher': app.publisher,
      'hive': app.registryHive,
      'view': app.registryView,
      'key': app.registryKey,
      'location': app.installLocation,
    })));
    final raw = await _runJson('''$_jsonHeader
\$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json
\$items = New-Object System.Collections.Generic.List[object]
\$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
function Add-Candidate([string]\$path, [string]\$kind, [string]\$note, [string]\$targetType, [string]\$hive='', [string]\$view='', [string]\$registryPath='') {
  if ([string]::IsNullOrWhiteSpace(\$path)) { return }
  if (\$seen.Add(\$targetType + '|' + \$path)) {
    \$items.Add([PSCustomObject]@{path=\$path; kind=\$kind; note=\$note; targetType=\$targetType; registryHive=\$hive; registryView=\$view; registryPath=\$registryPath; canDelete=\$true})
  }
}
function Safe-Name([string]\$value) {
  return ((\$value -replace '[\\\\/:*?"<>|]', '_').Trim().TrimEnd('.'))
}
function Safe-RegistryPart([string]\$value) {
  return ((\$value -replace '[\\\\/]', '_').Trim())
}
\$protected = New-Object System.Collections.Generic.List[string]
foreach (\$entry in @([IO.Path]::GetPathRoot(\$env:SystemDrive + '\\'), \$env:SystemRoot, \$env:ProgramFiles, \${env:ProgramFiles(x86)}, \$env:ProgramData, \$env:USERPROFILE, \$env:LOCALAPPDATA, \$env:APPDATA, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))) {
  if (-not [string]::IsNullOrWhiteSpace(\$entry)) { \$protected.Add([IO.Path]::GetFullPath(\$entry).TrimEnd('\\')) }
}
function Add-PathCandidate([string]\$candidate, [string]\$kind, [string]\$note) {
  if ([string]::IsNullOrWhiteSpace(\$candidate) -or -not [IO.Path]::IsPathRooted(\$candidate)) { return }
  try {
    \$full = [IO.Path]::GetFullPath(\$candidate).TrimEnd('\\')
    foreach (\$entry in \$protected) {
      if (\$full.Equals(\$entry, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    if (\$full.StartsWith((\$env:SystemRoot.TrimEnd('\\') + '\\'), [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not (Test-Path -LiteralPath \$full)) { return }
    \$item = Get-Item -LiteralPath \$full -Force
    if ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    Add-Candidate \$full \$kind \$note 'directory'
  } catch {}
}

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
    Add-Candidate (\$base.Name + '\\' + \$path) '卸载注册项' '官方卸载完成后仍存在的登记项；删除前请确认软件确实不再需要修复或升级。' 'registry' ([string]\$request.hive) ([string]\$request.view) \$path
  }
} finally { if (\$null -ne \$key) { \$key.Dispose() }; \$base.Dispose() }
\$location = [Environment]::ExpandEnvironmentVariables([string]\$request.location)
Add-PathCandidate \$location '原安装目录' '由 InstallLocation 登记；可能包含共享文件或个人数据，请核对后删除。'

\$name = Safe-Name ([string]\$request.name)
\$publisher = Safe-Name ([string]\$request.publisher)
\$registryName = Safe-RegistryPart ([string]\$request.name)
\$registryPublisher = Safe-RegistryPart ([string]\$request.publisher)
if (-not [string]::IsNullOrWhiteSpace(\$name)) {
  \$candidates = @(
    @{path=(Join-Path \$env:LOCALAPPDATA ('Programs\\' + \$name)); kind='用户安装目录'; note='LocalAppData\\Programs 下的同名安装目录。'},
    @{path=(Join-Path \$env:LOCALAPPDATA \$name); kind='用户数据目录'; note='LocalAppData 下的同名应用数据。'},
    @{path=(Join-Path \$env:APPDATA \$name); kind='漫游数据目录'; note='AppData\\Roaming 下的同名应用数据。'},
    @{path=(Join-Path \$env:PROGRAMDATA \$name); kind='共享数据目录'; note='ProgramData 下的同名共享数据。'},
    @{path=(Join-Path \$env:ProgramFiles \$name); kind='程序目录'; note='Program Files 下的同名目录。'},
    @{path=(Join-Path \$env:APPDATA ('Microsoft\\Windows\\Start Menu\\Programs\\' + \$name)); kind='开始菜单目录'; note='当前用户开始菜单中的同名快捷方式目录。'},
    @{path=(Join-Path \$env:PROGRAMDATA ('Microsoft\\Windows\\Start Menu\\Programs\\' + \$name)); kind='开始菜单目录'; note='所有用户开始菜单中的同名快捷方式目录。'}
  )
  if (-not [string]::IsNullOrWhiteSpace(\${env:ProgramFiles(x86)})) {
    \$candidates += @{path=(Join-Path \${env:ProgramFiles(x86)} \$name); kind='程序目录'; note='Program Files (x86) 下的同名目录。'}
  }
  if (-not [string]::IsNullOrWhiteSpace(\$publisher)) {
    \$candidates += @(
      @{path=(Join-Path \$env:LOCALAPPDATA (\$publisher + '\\' + \$name)); kind='发布者数据目录'; note='LocalAppData 下按发布者和软件名匹配的目录。'},
      @{path=(Join-Path \$env:APPDATA (\$publisher + '\\' + \$name)); kind='发布者数据目录'; note='AppData\\Roaming 下按发布者和软件名匹配的目录。'},
      @{path=(Join-Path \$env:PROGRAMDATA (\$publisher + '\\' + \$name)); kind='发布者共享目录'; note='ProgramData 下按发布者和软件名匹配的目录。'}
    )
  }
  foreach (\$candidate in \$candidates) { Add-PathCandidate \$candidate.path \$candidate.kind \$candidate.note }
}

\$scanViews = @(\$view)
if ([Environment]::Is64BitOperatingSystem -and \$view -ne [Microsoft.Win32.RegistryView]::Registry64) {
  \$scanViews += [Microsoft.Win32.RegistryView]::Registry64
}
foreach (\$hiveName in @('CurrentUser', 'LocalMachine')) {
  \$scanHive = [Microsoft.Win32.RegistryHive]::CurrentUser
  if (\$hiveName -eq 'LocalMachine') { \$scanHive = [Microsoft.Win32.RegistryHive]::LocalMachine }
  foreach (\$scanView in \$scanViews) {
    \$scanBase = \$null
    try {
      \$scanBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(\$scanHive, \$scanView)
      \$relativeKeys = @()
      if (-not [string]::IsNullOrWhiteSpace(\$registryName)) { \$relativeKeys += ('SOFTWARE\\' + \$registryName) }
      if (-not [string]::IsNullOrWhiteSpace(\$registryPublisher) -and -not [string]::IsNullOrWhiteSpace(\$registryName)) {
        \$relativeKeys += ('SOFTWARE\\' + \$registryPublisher + '\\' + \$registryName)
      }
      foreach (\$relative in \$relativeKeys) {
        \$found = \$null
        try {
          \$found = \$scanBase.OpenSubKey(\$relative, \$false)
          if (\$null -ne \$found) {
            Add-Candidate (\$scanBase.Name + '\\' + \$relative) '用户设置残留' '按软件名称精确匹配的注册表设置；可能包含仍需保留的授权或个人配置。' 'registry' \$hiveName ([string]\$scanView) \$relative
          }
        } finally { if (\$null -ne \$found) { \$found.Dispose() } }
      }
    } catch {}
    finally { if (\$null -ne \$scanBase) { \$scanBase.Dispose() } }
  }
}
ConvertTo-Json -InputObject @(\$items.ToArray()) -Depth 4 -Compress
''');
    return (raw as List)
        .map((item) => WindowsResidueCandidate(
              path: item['path'].toString(),
              kind: item['kind'].toString(),
              note: item['note'].toString(),
              targetType: item['targetType']?.toString() ?? '',
              registryHive: item['registryHive']?.toString() ?? '',
              registryView: item['registryView']?.toString() ?? '',
              registryPath: item['registryPath']?.toString() ?? '',
              canDelete: item['canDelete'] == true,
            ))
        .toList();
  }

  Future<WindowsResidueActionResult> deleteResidue(
      List<WindowsResidueCandidate> candidates) async {
    final removable = candidates.where((item) => item.canDelete).toList();
    if (removable.isEmpty) return const WindowsResidueActionResult();
    final payload = base64Encode(utf8.encode(jsonEncode({
      'candidates': [
        for (final item in removable)
          {
            'path': item.path,
            'targetType': item.targetType,
            'registryHive': item.registryHive,
            'registryView': item.registryView,
            'registryPath': item.registryPath,
          }
      ],
    })));
    final raw = await _runJson('''$_jsonHeader
\$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json
\$deleted = New-Object System.Collections.Generic.List[string]
\$errors = New-Object System.Collections.Generic.List[object]
\$protected = @([IO.Path]::GetPathRoot(\$env:SystemDrive + '\\'), \$env:SystemRoot, \$env:ProgramFiles, \${env:ProgramFiles(x86)}, \$env:ProgramData, \$env:USERPROFILE, \$env:LOCALAPPDATA, \$env:APPDATA, [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'))
foreach (\$candidate in @(\$request.candidates)) {
  try {
    if ([string]\$candidate.targetType -eq 'registry') {
      \$relative = [string]\$candidate.registryPath
      if ([string]::IsNullOrWhiteSpace(\$relative) -or -not \$relative.StartsWith('SOFTWARE\\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '注册表路径不在允许范围。'
      }
      if (\$relative.TrimEnd('\\').Equals('SOFTWARE', [StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝删除整个 SOFTWARE 注册表根。'
      }
      \$hive = [Microsoft.Win32.RegistryHive]::LocalMachine
      if ([string]\$candidate.registryHive -eq 'CurrentUser') { \$hive = [Microsoft.Win32.RegistryHive]::CurrentUser }
      \$view = [Microsoft.Win32.RegistryView]::Registry32
      if ([string]\$candidate.registryView -eq 'Registry64') { \$view = [Microsoft.Win32.RegistryView]::Registry64 }
      \$base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(\$hive, \$view)
      try { \$base.DeleteSubKeyTree(\$relative, \$false) } finally { \$base.Dispose() }
      \$deleted.Add([string]\$candidate.path)
      continue
    }
    \$full = [IO.Path]::GetFullPath([string]\$candidate.path).TrimEnd('\\')
    foreach (\$entry in \$protected) {
      if (-not [string]::IsNullOrWhiteSpace(\$entry) -and \$full.Equals([IO.Path]::GetFullPath(\$entry).TrimEnd('\\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝删除受保护目录。'
      }
    }
    if (\$full.StartsWith((\$env:SystemRoot.TrimEnd('\\') + '\\'), [StringComparison]::OrdinalIgnoreCase)) {
      throw '拒绝删除 Windows 系统目录。'
    }
    if (-not (Test-Path -LiteralPath \$full)) {
      \$deleted.Add([string]\$candidate.path)
      continue
    }
    \$item = Get-Item -LiteralPath \$full -Force
    if ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw '拒绝跟随符号链接或目录联接。'
    }
    Remove-Item -LiteralPath \$full -Recurse:\$item.PSIsContainer -Force
    \$deleted.Add([string]\$candidate.path)
  } catch {
    \$errors.Add([PSCustomObject]@{path=[string]\$candidate.path; message=\$_.Exception.Message})
  }
}
[PSCustomObject]@{deletedPaths=@(\$deleted.ToArray()); errors=@(\$errors.ToArray())} | ConvertTo-Json -Depth 4 -Compress
''');
    final data = Map<String, dynamic>.from(raw as Map);
    return WindowsResidueActionResult(
      deletedPaths: (data['deletedPaths'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
      errors: (data['errors'] as List? ?? const [])
          .map((item) => item is Map
              ? '${item['path']}: ${item['message']}'
              : item.toString())
          .toList(),
    );
  }
}
